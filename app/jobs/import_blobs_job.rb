# ImportBlobsJob - Blob transfer job for Eurosky migration
#
# This is the most critical job in the migration pipeline.
# It handles downloading blobs from the old PDS and uploading them to the new PDS
# with concurrency control. Blobs are streamed to/from disk, so memory usage per
# blob is limited to the HTTP chunk size (~16KB) regardless of blob size.
#
# Critical Features:
# - Parallel blob processing (5 threads per migration, no global limit)
# - All migrations run independently — no queuing, no gating
# - Batched progress updates (every 10 blobs to reduce DB writes)
# - Individual blob retry with exponential backoff
# - Post-import reconciliation to fill gaps
#
# Flow:
# 1. Mark blobs_started_at timestamp
# 2. List all blobs with pagination (cursor-based, no auth required)
# 3. Update migration with blob_count
# 4. Process blobs in parallel (5 threads per migration):
#    - Download blob (streamed to disk)
#    - Upload blob (streamed from disk)
#    - Delete local blob file immediately after upload
#    - Update progress every 10 blobs
# 5. Reconcile - verify all blobs were imported and fill gaps
# 6. Mark blobs_completed_at timestamp
# 7. Advance to pending_prefs status
#
# Error Handling:
# - Rate-limit errors: longer exponential backoff (8s, 16s, 32s), max 3 attempts per blob
# - Network errors: standard exponential backoff (2s, 4s, 8s), max 3 attempts per blob
# - Job-level rate-limiting: retry entire job up to 5 times with polynomial backoff
# - Overall job failure: mark migration as failed
# - Log warnings for individual blob failures, don't fail entire job
#
# Usage:
#   ImportBlobsJob.perform_later(migration.id)
#
# ActiveJob/Sidekiq Configuration:
#   queue: :migrations
#   retry: 3

class ImportBlobsJob < ApplicationJob
  queue_as :migrations

  # Constants
  PARALLEL_BLOBS = 5
  MAX_BLOB_RETRIES = 3
  PROGRESS_UPDATE_INTERVAL = 10 # Update progress every N blobs

  # Retry configuration (3 attempts with exponential backoff)
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  # Special handling for rate-limiting errors with longer backoff
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform(migration_id)
    migration = Migration.find(migration_id)
    logger.info("Starting blob import for migration #{migration.token} (DID: #{migration.did})")

    # Idempotency check: Skip if already past this stage
    if migration.status != 'pending_blobs'
      logger.info("Migration #{migration.token} is already at status '#{migration.status}', skipping blob import")
      return
    end

    # Step 1: Mark blobs_started_at
    mark_blobs_started(migration)

    # Step 2: Initialize GoatService
    goat = GoatService.new(migration)

    # Step 3: List all blobs with pagination (no authentication required for public sync endpoints)
    all_blobs = collect_all_blobs(goat)

    logger.info("Found #{all_blobs.length} total blobs to transfer")

    # Step 4: Update migration with blob count
    migration.update!(
      progress_data: migration.progress_data.merge('blob_count' => all_blobs.length)
    )

    # Step 5: Process blobs in parallel
    process_blobs(migration, goat, all_blobs)

    # Step 6: Reconcile - verify all blobs were imported and fill gaps
    reconcile_blobs(migration, goat)

    # Step 7: Mark blobs_completed_at
    mark_blobs_completed(migration)

    logger.info("Blob import completed for migration #{migration.token}")

    # Step 8: Advance to next stage
    migration.advance_to_pending_prefs!

  rescue Migration::Aborted => e
    # Cancelled, failed or completed underneath us - stop without retrying
    logger.warn(e.message)

  rescue StandardError => e
    logger.error("Blob import failed for migration #{migration&.id || migration_id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))

    if migration
      migration.reload
      migration.mark_failed!("Blob import failed: #{e.message}", error_code: :generic)
    end

    raise
  end

  private

  # Mark the start time for blob transfer
  def mark_blobs_started(migration)
    migration.progress_data ||= {}
    migration.progress_data['blobs_started_at'] = Time.current.iso8601
    migration.save!
  end

  # Mark the completion time for blob transfer
  def mark_blobs_completed(migration)
    migration.progress_data ||= {}
    migration.progress_data['blobs_completed_at'] = Time.current.iso8601
    migration.save!
  end

  # Collect all blobs using cursor-based pagination
  def collect_all_blobs(goat)
    all_blobs = []
    cursor = nil

    loop do
      response = goat.list_blobs(cursor)

      cids = response['cids'] || []
      all_blobs.concat(cids)

      cursor = response['cursor']
      break if cursor.nil? || cursor.empty?

      logger.debug("Fetched #{cids.length} blobs, cursor: #{cursor}")
    end

    all_blobs
  end

  # Process all blobs using a thread pool (PARALLEL_BLOBS threads per migration).
  # Every migration runs its own pool independently — no global gating.
  def process_blobs(migration, goat, blobs)
    # Login to new PDS for uploads
    goat.login_new_pds

    total_bytes_transferred = 0
    successful_count = 0
    failed_cids = []

    # Thread-safe counters and queue
    mutex = Mutex.new
    queue = Queue.new
    aborted = false # set when the migration is cancelled/failed while transferring

    # Add all blobs to the queue
    blobs.each_with_index { |cid, index| queue << [cid, index] }

    # Release the main thread's DB connection before entering the thread pool.
    # It's idle during blob transfers (just waiting on thread joins) and holding
    # it would waste a pooled connection for the entire duration.
    ActiveRecord::Base.connection_pool.release_connection

    # Create worker threads (thread pool)
    threads = PARALLEL_BLOBS.times.map do
      Thread.new do
        loop do
          break if aborted

          # Get next blob from queue (non-blocking)
          begin
            cid, index = queue.pop(true)
          rescue ThreadError
            # Queue is empty, thread can exit
            break
          end

          begin
            # Download blob from old PDS (streamed to disk)
            blob_path = download_blob_with_retry(goat, cid)

            # Get file size for tracking
            blob_size = File.size(blob_path)

            # Upload blob to new PDS (streamed from disk)
            upload_blob_with_retry(goat, blob_path)

            # Update metrics (thread-safe)
            mutex.synchronize do
              total_bytes_transferred += blob_size
              successful_count += 1
            end

            # Log transfer
            logger.info("Transferred blob #{index + 1}/#{blobs.length}: #{cid} (#{format_bytes(blob_size)})")

            # Delete local file immediately
            FileUtils.rm_f(blob_path)

            # Update progress periodically.
            # Use with_connection to borrow and return a DB connection immediately,
            # preventing worker threads from hoarding pooled connections.
            if (index + 1) % PROGRESS_UPDATE_INTERVAL == 0
              mutex.synchronize do
                ActiveRecord::Base.connection_pool.with_connection do
                  update_blob_progress(migration, successful_count, blobs.length, total_bytes_transferred)
                  aborted = true if migration.terminal_in_db?
                end
              end
            end

          rescue StandardError => e
            logger.error("Failed to transfer blob #{cid}: #{e.message}")
            mutex.synchronize do
              failed_cids << cid
            end
          end
        end
      end
    end

    # Wait for all worker threads to complete
    threads.each(&:join)

    # Final progress update
    update_blob_progress(migration, successful_count, blobs.length, total_bytes_transferred)

    raise Migration::Aborted, "Migration #{migration.token} was cancelled or failed during blob transfer; stopping" if aborted

    # Log summary
    logger.info("Blob transfer complete: #{successful_count}/#{blobs.length} successful")
    logger.info("Total data transferred: #{format_bytes(total_bytes_transferred)}")

    if failed_cids.any?
      logger.warn("Failed to transfer #{failed_cids.length} blobs: #{failed_cids.join(', ')}")

      # Save failed blobs to migration metadata
      migration.progress_data ||= {}
      migration.progress_data['failed_blobs'] = failed_cids
      migration.save!

      # Write failed blobs manifest for visibility
      if migration.downloaded_data_path.present?
        manifest_path = File.join(migration.downloaded_data_path, 'FAILED_BLOB_UPLOADS.txt')
        File.write(manifest_path, <<~MANIFEST)
          FAILED BLOB UPLOADS REPORT
          ==========================

          Migration: #{migration.token}
          DID: #{migration.did}
          Date: #{Time.current.iso8601}

          Total blobs: #{blobs.length}
          Successfully transferred: #{successful_count}
          Failed to upload: #{failed_cids.length}

          FAILED BLOB CIDs:
          #{failed_cids.map { |cid| "  - #{cid}" }.join("\n")}

          These blobs were downloaded from the old PDS but failed to upload to the new PDS
          due to network errors or timeouts. You may need to re-upload these manually.
        MANIFEST

        logger.info("Wrote failed uploads manifest to #{manifest_path}")
      end
    end
  end

  # Download blob with retry logic
  def download_blob_with_retry(goat, cid, attempt = 1)
    goat.download_blob(cid)
  rescue GoatService::RateLimitError => e
    if attempt < MAX_BLOB_RETRIES
      backoff = 2 ** (attempt + 2) # Longer backoff for rate limits: 8s, 16s, 32s
      logger.warn("Rate limit hit downloading blob (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{cid} - retrying in #{backoff}s")
      sleep(backoff)
      download_blob_with_retry(goat, cid, attempt + 1)
    else
      logger.error("Blob download failed after #{MAX_BLOB_RETRIES} rate-limit retries: #{cid}")
      raise
    end
  rescue GoatService::NetworkError, GoatService::TimeoutError => e
    if attempt < MAX_BLOB_RETRIES
      logger.warn("Blob download failed (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{cid} - #{e.message}")
      sleep(2 ** attempt) # Exponential backoff: 2s, 4s, 8s
      download_blob_with_retry(goat, cid, attempt + 1)
    else
      logger.error("Blob download failed after #{MAX_BLOB_RETRIES} attempts: #{cid}")
      raise
    end
  end

  # Upload blob with retry logic
  def upload_blob_with_retry(goat, blob_path, attempt = 1)
    goat.upload_blob(blob_path)
  rescue GoatService::RateLimitError => e
    if attempt < MAX_BLOB_RETRIES
      backoff = 2 ** (attempt + 2) # Longer backoff for rate limits: 8s, 16s, 32s
      logger.warn("Rate limit hit uploading blob (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{blob_path} - retrying in #{backoff}s")
      sleep(backoff)
      upload_blob_with_retry(goat, blob_path, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_BLOB_RETRIES} rate-limit retries: #{blob_path}")
      raise
    end
  rescue GoatService::NetworkError, GoatService::TimeoutError => e
    if attempt < MAX_BLOB_RETRIES
      logger.warn("Blob upload failed (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{blob_path} - #{e.message}")
      sleep(2 ** attempt) # Exponential backoff: 2s, 4s, 8s
      upload_blob_with_retry(goat, blob_path, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_BLOB_RETRIES} attempts: #{blob_path}")
      raise
    end
  end

  # Update progress tracking in database
  def update_blob_progress(migration, completed, total, bytes_transferred)
    # Atomic JSONB merge: never writes back a stale copy of progress_data
    # (which would drop keys such as cancelled_at written by the controller).
    migration.merge_progress!(
      'blobs_completed' => completed,
      'blobs_total' => total,
      'bytes_transferred' => bytes_transferred,
      'last_progress_update' => Time.current.iso8601
    )

    logger.debug("Progress: #{completed}/#{total} blobs (#{format_bytes(bytes_transferred)})")
  end

  # Post-import blob reconciliation.
  # Checks account status to compare expected vs imported blobs,
  # then fetches and uploads any missing blobs. Best-effort: failures
  # are logged but do not fail the migration.
  def reconcile_blobs(migration, goat)
    logger.info("Starting post-import blob reconciliation")

    migration.progress_data ||= {}
    migration.progress_data['reconciliation_started_at'] = Time.current.iso8601
    migration.save!

    # Step 1: Check account status to see if there's a mismatch
    begin
      status = goat.get_account_status
      expected = status['expectedBlobs'] || 0
      imported = status['importedBlobs'] || 0

      logger.info("Blob reconciliation: expected=#{expected}, imported=#{imported}")

      migration.progress_data['reconciliation_expected_blobs'] = expected
      migration.progress_data['reconciliation_imported_blobs'] = imported
      migration.save!

      if expected == imported
        logger.info("All blobs accounted for, no reconciliation needed")
        migration.progress_data['reconciliation_status'] = 'complete'
        migration.progress_data['reconciliation_completed_at'] = Time.current.iso8601
        migration.save!
        return
      end

      logger.warn("Blob mismatch detected: #{expected - imported} blobs missing")
    rescue StandardError => e
      logger.error("Failed to check account status during reconciliation: #{e.message}")
      migration.progress_data['reconciliation_status'] = 'skipped'
      migration.progress_data['reconciliation_error'] = "Account status check failed: #{e.message}"
      migration.save!
      return
    end

    # Step 2: Get the list of missing blob CIDs
    begin
      missing_cids = goat.collect_all_missing_blobs
      logger.info("Found #{missing_cids.length} missing blobs to reconcile")

      migration.progress_data['reconciliation_missing_count'] = missing_cids.length
      migration.save!
    rescue StandardError => e
      logger.error("Failed to list missing blobs during reconciliation: #{e.message}")
      migration.progress_data['reconciliation_status'] = 'partial'
      migration.progress_data['reconciliation_error'] = "List missing blobs failed: #{e.message}"
      migration.save!
      return
    end

    if missing_cids.empty?
      logger.info("No missing blobs returned despite count mismatch (may be eventual consistency)")
      migration.progress_data['reconciliation_status'] = 'complete'
      migration.progress_data['reconciliation_completed_at'] = Time.current.iso8601
      migration.save!
      return
    end

    # Step 3: Attempt to fetch and upload each missing blob
    reconciled_count = 0
    still_missing = []

    missing_cids.each_with_index do |cid, index|
      begin
        logger.info("Reconciling missing blob #{index + 1}/#{missing_cids.length}: #{cid}")

        # Download from old PDS
        blob_path = goat.download_blob(cid)
        blob_size = File.size(blob_path)

        # Upload to new PDS
        goat.upload_blob(blob_path)

        # Cleanup
        FileUtils.rm_f(blob_path)

        reconciled_count += 1
        logger.info("Reconciled blob #{cid} (#{blob_size} bytes)")
      rescue StandardError => e
        logger.warn("Failed to reconcile blob #{cid}: #{e.message}")
        still_missing << cid
      end
    end

    # Step 4: Record reconciliation results
    migration.progress_data['reconciliation_status'] = still_missing.empty? ? 'complete' : 'partial'
    migration.progress_data['reconciliation_recovered'] = reconciled_count
    migration.progress_data['reconciliation_still_missing'] = still_missing if still_missing.any?
    migration.progress_data['reconciliation_completed_at'] = Time.current.iso8601
    migration.save!

    logger.info("Blob reconciliation finished: #{reconciled_count}/#{missing_cids.length} recovered, #{still_missing.length} still missing")

    if still_missing.any?
      # Merge still-missing blobs into the failed_blobs list
      existing_failed = migration.progress_data['failed_blobs'] || []
      all_failed = (existing_failed + still_missing).uniq
      migration.progress_data['failed_blobs'] = all_failed
      migration.save!

      logger.warn("#{still_missing.length} blobs could not be reconciled: #{still_missing.join(', ')}")
    end
  rescue StandardError => e
    # Best-effort: log the error but don't fail the migration
    logger.error("Blob reconciliation failed unexpectedly: #{e.message}")
    logger.error(e.backtrace&.first(5)&.join("\n"))

    migration.progress_data ||= {}
    migration.progress_data['reconciliation_status'] = 'error'
    migration.progress_data['reconciliation_error'] = e.message
    migration.save!
  end

  # Format bytes for human-readable output
  def format_bytes(bytes)
    return "0 B" if bytes.zero?

    units = ['B', 'KB', 'MB', 'GB', 'TB']
    exp = (Math.log(bytes) / Math.log(1024)).to_i
    exp = [exp, units.length - 1].min

    value = bytes.to_f / (1024 ** exp)
    "#{value.round(2)} #{units[exp]}"
  end
end
