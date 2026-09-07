class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Silently discard jobs whose Migration record has been deleted.
  # This happens when stale jobs (e.g. mailer notifications) remain in the
  # Sidekiq queue after a migration is cleaned up or the DB is reset.
  discard_on ActiveJob::DeserializationError

  private

  # --- Blob-stage telemetry --------------------------------------------------
  #
  # A "pass" is one sweep over a set of blobs: the parallel pool, the
  # sequential second pass, reconciliation, or a background retry. Open one
  # with #start_blob_pass, close it from the method's `ensure` so a crash
  # halfway still leaves the numbers behind, and wrap each transfer in
  # #measure.
  #
  # #measure is a plain passthrough when no pass is open, so the transfer code
  # reads the same whether or not it is being measured, and the jobs' existing
  # retry and error handling is untouched.

  def start_blob_pass(migration, pass:, goat: nil)
    @blob_telemetry = BlobTransferTelemetry.new(
      migration, job_name: self.class.name, pass: pass, goat: goat
    )
  end

  def finish_blob_pass
    @blob_telemetry&.finish!
    @blob_telemetry = nil
  end

  def measure(cid:, phase: :upload, bytes: nil, &block)
    return yield unless @blob_telemetry

    @blob_telemetry.attempt(cid: cid, phase: phase, bytes: bytes, &block)
  end

  # Count a blob the pass was responsible for but never attempted, so a pass
  # that gave up halfway cannot be mistaken for a clean one.
  def skip_blob(cid)
    @blob_telemetry&.skipped(cid)
  end

  # Size of a blob on disk, or nil if it has gone. Measuring a transfer must
  # never be the thing that breaks it.
  def file_size(path)
    File.size(path)
  rescue SystemCallError
    nil
  end
end
