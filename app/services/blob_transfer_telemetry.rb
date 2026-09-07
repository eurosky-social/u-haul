# frozen_string_literal: true

# Collects what actually happened to every blob in one pass, then writes it
# down somewhere that outlives the container log.
#
# The blob stage is where migrations fail, and the evidence has always been
# free text in `docker logs` - which rotates. So "are we failing more than we
# were last month?", "is it 500s or timeouts?" and "how fast are uploads
# really going?" were only answerable for a few days after the fact, by
# grepping. One BlobTransferStat row per pass makes them answerable in SQL.
#
# The jobs drive this through ApplicationJob's #start_blob_pass / #measure /
# #finish_blob_pass, which keeps the transfer code unindented and closes the
# pass from the method's `ensure`. .record is the equivalent block form:
#
#   BlobTransferTelemetry.record(migration, job_name: self.class.name,
#                                pass: BlobTransferTelemetry::PASS_PARALLEL,
#                                goat: goat) do |telemetry|
#     telemetry.attempt(cid: cid, phase: :upload, bytes: size) do
#       goat.upload_blob(path)
#     end
#   end
#
# Thread-safe: the blob jobs point PARALLEL_BLOBS worker threads at a single
# instance. Nothing here touches the database until #finish!, so it is safe to
# use inside the pool after the jobs release their connection.
#
# Telemetry never breaks a migration: #finish! swallows its own errors.
class BlobTransferTelemetry
  # Enough failures to see a pattern, few enough that the row stays small.
  MAX_FAILURE_SAMPLES = 25
  # Failure messages can carry a PDS error body; keep only the useful head.
  MAX_MESSAGE_LENGTH = 300

  PASS_PARALLEL   = 'parallel'
  PASS_SEQUENTIAL = 'sequential'
  PASS_RECONCILE  = 'reconcile'
  PASS_RETRY      = 'retry'

  attr_reader :started_at

  # Runs the block with a collector and records the result either way - an
  # exception mid-pass still leaves the evidence behind.
  def self.record(migration, job_name:, pass:, goat: nil, logger: Rails.logger)
    telemetry = new(migration, job_name: job_name, pass: pass, goat: goat, logger: logger)
    begin
      yield telemetry
    ensure
      telemetry.finish!
    end
  end

  def initialize(migration, job_name:, pass:, goat: nil, logger: Rails.logger)
    @migration = migration
    @job_name = job_name
    @pass = pass
    @goat = goat
    @logger = logger

    @mutex = Mutex.new
    @started_at = Time.current
    @started_ms = monotonic_ms

    @outcomes = Hash.new(0)
    @failures = []
    @upload_ms = []
    @upload_bps = []
    @bytes = 0
    @upload_attempts = 0
    # cid => whether it ever uploaded successfully
    @blobs = {}
    @finished = false
  end

  # Times one attempt at one blob and records how it went. Re-raises, so the
  # callers' existing retry and error handling is untouched - a retried blob
  # simply shows up as several attempts and one final outcome.
  def attempt(cid:, phase: :upload, bytes: nil)
    started = monotonic_ms
    result = yield
    record(cid: cid, phase: phase, outcome: 'ok', ms: monotonic_ms - started, bytes: bytes)
    result
  rescue StandardError => e
    record(cid: cid, phase: phase, outcome: classify(e), ms: monotonic_ms - started, error: e)
    raise
  end

  # Note a blob the pass was responsible for but never got to attempt, so the
  # denominator stays honest (a pass abandoned halfway should not look clean).
  def skipped(cid)
    @mutex.synchronize { @blobs[cid] ||= false }
  end

  # Persist the pass and emit one structured line for Loki. Idempotent.
  def finish!
    return if @finished

    @finished = true
    attempted = @blobs.length
    return if attempted.zero?

    duration_ms = monotonic_ms - @started_ms
    succeeded = @blobs.count { |_cid, ok| ok }

    stat = BlobTransferStat.create!(
      migration: @migration,
      job_name: @job_name,
      pass: @pass,
      source_host: @migration&.old_pds_host,
      target_host: @migration&.new_pds_host,
      target_pds_version: target_pds_version,
      started_at: @started_at,
      finished_at: Time.current,
      duration_ms: duration_ms,
      blobs_attempted: attempted,
      blobs_succeeded: succeeded,
      blobs_failed: attempted - succeeded,
      upload_attempts: @upload_attempts,
      bytes_transferred: @bytes,
      throughput_bps: rate(@bytes, duration_ms),
      upload_bps_p50: percentile(@upload_bps, 50),
      upload_ms_p50: percentile(@upload_ms, 50),
      upload_ms_p95: percentile(@upload_ms, 95),
      upload_ms_max: @upload_ms.max,
      outcome_counts: @outcomes,
      failure_samples: @failures
    )

    log_summary(stat)
    stat
  rescue StandardError => e
    # Losing the numbers is not a reason to lose the migration.
    @logger.error("Blob telemetry could not be recorded: #{e.class}: #{e.message}")
    nil
  end

  private

  def record(cid:, phase:, outcome:, ms:, bytes: nil, error: nil)
    phase = phase.to_s

    @mutex.synchronize do
      @outcomes["#{phase}.#{outcome}"] += 1
      @blobs[cid] ||= false
      @upload_attempts += 1 if phase == 'upload'

      if outcome == 'ok' && phase == 'upload'
        @blobs[cid] = true
        @bytes += bytes.to_i
        @upload_ms << ms
        @upload_bps << rate(bytes.to_i, ms) if bytes.to_i.positive?
      end

      collect_failure(cid, phase, outcome, ms, error) unless outcome == 'ok'
    end
  end

  # Which bucket a failure belongs in. Coarse on purpose: the buckets are what
  # gets counted, and the exact exception is kept in the failure sample.
  def classify(error)
    case error
    when GoatService::RateLimitError then 'rate_limited'
    when GoatService::TimeoutError then 'timeout'
    else
      status = error.respond_to?(:http_status) ? error.http_status : nil
      status ? "http_#{status}" : 'error'
    end
  end

  def collect_failure(cid, phase, outcome, ms, error)
    return if @failures.length >= MAX_FAILURE_SAMPLES

    @failures << {
      'cid' => cid,
      'phase' => phase,
      'outcome' => outcome,
      'ms' => ms,
      'error_class' => error&.class&.name,
      'message' => error&.message.to_s[0, MAX_MESSAGE_LENGTH].presence
    }.compact
  end

  # Bytes per second, guarding the zero-duration case.
  def rate(bytes, ms)
    return nil unless ms.to_i.positive?

    ((bytes.to_f * 1000) / ms).round
  end

  def percentile(values, pct)
    return nil if values.empty?

    sorted = values.sort
    index = ((pct / 100.0) * (sorted.length - 1)).round
    sorted[index]
  end

  # Best-effort: an unreachable /xrpc/_health must not fail the pass, it just
  # leaves the version unknown for that row.
  def target_pds_version
    @goat&.target_pds_version
  rescue StandardError => e
    @logger.debug("Could not read target PDS version: #{e.message}")
    nil
  end

  # One line, stable prefix, JSON payload - so the same numbers are available
  # in Loki without waiting for someone to run the rake task.
  def log_summary(stat)
    @logger.info("blob_transfer_summary #{{
      migration_id: stat.migration_id,
      job: stat.job_name,
      pass: stat.pass,
      target_host: stat.target_host,
      target_pds_version: stat.target_pds_version,
      blobs_attempted: stat.blobs_attempted,
      blobs_succeeded: stat.blobs_succeeded,
      blobs_failed: stat.blobs_failed,
      upload_attempts: stat.upload_attempts,
      bytes: stat.bytes_transferred,
      duration_ms: stat.duration_ms,
      throughput_bps: stat.throughput_bps,
      upload_bps_p50: stat.upload_bps_p50,
      upload_ms_p95: stat.upload_ms_p95,
      outcomes: stat.outcome_counts
    }.to_json}")
  end

  def monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
  end
end
