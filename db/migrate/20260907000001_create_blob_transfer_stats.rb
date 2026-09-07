# frozen_string_literal: true

# One row per blob-stage pass, kept as the durable record of how the blob
# transfer actually went.
#
# migration_id is nullable and the foreign key nullifies on delete on purpose:
# CleanupOldMigrationsJob destroys completed migrations after 2 days and failed
# ones after 7, so anything cascaded from `migrations` would be gone long
# before it could answer "did the PDS upgrade change our success rate?".
# Nothing here identifies a user - no token, no DID, no email.
class CreateBlobTransferStats < ActiveRecord::Migration[7.1]
  def change
    create_table :blob_transfer_stats do |t|
      t.references :migration, null: true, foreign_key: { on_delete: :nullify }

      t.string :job_name, null: false
      t.string :pass, null: false
      t.string :source_host
      t.string :target_host
      # Target PDS version at the time of the pass, read from /xrpc/_health.
      # This is the column that makes a before/after comparison possible.
      t.string :target_pds_version

      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :duration_ms

      t.integer :blobs_attempted, null: false, default: 0
      t.integer :blobs_succeeded, null: false, default: 0
      t.integer :blobs_failed, null: false, default: 0
      # Attempts include retries, so attempts >> attempted means retry pressure.
      t.integer :upload_attempts, null: false, default: 0

      t.bigint :bytes_transferred, null: false, default: 0
      # Aggregate over the whole pass (all worker threads together).
      t.integer :throughput_bps
      # Median throughput of a single upload. With the HAProxy blob shaper in
      # front of the PDS this sits at ~1_250_000; without it, it does not.
      t.integer :upload_bps_p50

      t.integer :upload_ms_p50
      t.integer :upload_ms_p95
      t.integer :upload_ms_max

      # Flat "<phase>.<outcome>" keys, e.g. "upload.ok", "upload.http_500",
      # "download.timeout". Flat so it stays trivially queryable in SQL.
      t.jsonb :outcome_counts, null: false, default: {}
      # Bounded sample of individual failures for diagnosis.
      t.jsonb :failure_samples, null: false, default: []

      t.timestamps
    end

    add_index :blob_transfer_stats, :created_at
    add_index :blob_transfer_stats, :target_pds_version
    add_index :blob_transfer_stats, :outcome_counts, using: :gin
  end
end
