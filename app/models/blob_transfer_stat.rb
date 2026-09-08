# frozen_string_literal: true

# The durable record of one blob-stage pass.
#
# Written by BlobTransferTelemetry; read by `rake blobs:stats` and by anyone
# asking why a migration finished with missing media. Rows outlive the
# migration they came from (see the create migration for why), so the table is
# the only place a question like "were we failing more before the PDS upgrade?"
# can still be answered a month later.
class BlobTransferStat < ApplicationRecord
  belongs_to :migration, optional: true

  # Which pass produced the row. A migration's blobs normally go through
  # `parallel`, and only the leftovers reach the later passes.
  PASSES = %w[parallel sequential reconcile retry].freeze

  validates :job_name, :pass, :started_at, presence: true
  validates :pass, inclusion: { in: PASSES }

  scope :since, ->(time) { where(created_at: time..) }
  scope :for_target, ->(host) { where(target_host: host) }
  scope :for_version, ->(version) { where(target_pds_version: version) }

  # Share of blobs this pass was asked to move that it actually moved.
  # nil rather than 100% when the pass had nothing to do, so empty passes
  # cannot flatter an average.
  def success_rate
    return nil if blobs_attempted.to_i.zero?

    blobs_succeeded.to_f / blobs_attempted
  end

  # Attempts per blob. 1.0 means nothing was retried; 3.0 means the pass was
  # fighting the target PDS for every file.
  def attempts_per_blob
    return nil if blobs_attempted.to_i.zero?

    upload_attempts.to_f / blobs_attempted
  end

  # Outcome buckets that are not "ok", biggest first - the failure profile.
  def failure_profile
    outcome_counts.reject { |key, _| key.end_with?('.ok') }
                  .sort_by { |_, count| -count }
                  .to_h
  end

  # Aggregate rows into one entry per (target host, PDS version).
  #
  # This is the shape the "did that change help?" question wants: the version
  # string moves when the PDS image is bumped, so the rows either side of the
  # bump line up next to each other — per host, because the two directions of
  # migration have nothing to say about each other.
  def self.summary(since: 7.days.ago, target_host: nil)
    scope = self.since(since)
    scope = scope.for_target(target_host) if target_host.present?

    # Keyed by host AND version. Migrations run in both directions, so the
    # target is sometimes the PDS we operate and sometimes the one the user is
    # leaving for; a version string alone says nothing about which. Worse, not
    # every PDS reports a version — bsky.social's /xrpc/_health answers with a
    # git SHA — so without the host these rows are unattributable.
    scope.group_by { |row| [row.target_host, row.target_pds_version || 'unknown'] }
         .map { |(host, version), rows| aggregate(host, version, rows) }
         .sort_by { |entry| -entry[:blobs_attempted] }
  end

  # Combine a set of rows into a single reportable entry.
  def self.aggregate(host, version, rows)
    attempted = rows.sum { |r| r.blobs_attempted.to_i }
    succeeded = rows.sum { |r| r.blobs_succeeded.to_i }
    bytes     = rows.sum { |r| r.bytes_transferred.to_i }
    bps       = rows.filter_map { |r| r.upload_bps_p50 if r.upload_bps_p50.to_i.positive? }

    outcomes = Hash.new(0)
    rows.each { |row| row.outcome_counts.each { |key, count| outcomes[key] += count } }

    {
      target_host: host,
      target_pds_version: version,
      passes: rows.length,
      migrations: rows.map(&:migration_id).compact.uniq.length,
      blobs_attempted: attempted,
      blobs_succeeded: succeeded,
      blobs_failed: attempted - succeeded,
      success_rate: attempted.zero? ? nil : succeeded.to_f / attempted,
      bytes_transferred: bytes,
      # Median of the per-pass medians: resistant to one huge migration
      # dominating the picture the way a mean would.
      upload_bps_p50: bps.empty? ? nil : median(bps),
      upload_ms_p95: median(rows.filter_map { |r| r.upload_ms_p95 if r.upload_ms_p95.to_i.positive? }),
      outcomes: outcomes.sort_by { |_, count| -count }.to_h,
      first_seen: rows.map(&:created_at).min,
      last_seen: rows.map(&:created_at).max
    }
  end

  def self.median(values)
    return nil if values.blank?

    sorted = values.sort
    middle = sorted.length / 2
    sorted.length.odd? ? sorted[middle] : ((sorted[middle - 1] + sorted[middle]) / 2.0).round
  end
end
