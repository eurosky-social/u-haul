# UploadBlobsJob - Uploads blobs from local files to new PDS
#
# This job uploads all blob files that were previously downloaded
# by DownloadAllDataJob. It's used when backup is enabled to avoid
# re-downloading the blobs. Uploads are streamed from disk, so memory
# usage per blob is limited to the HTTP chunk size (~16KB).
#
# Flow:
# 1. Verify local blobs directory exists
# 2. Login to new PDS
# 3. List all local blob files
# 4. Upload blobs in parallel (5 threads per migration, no global limit)
# 5. Track progress and update after each batch
# 6. Advance to pending_prefs status
#
# Differences from ImportBlobsJob:
# - ImportBlobsJob: Downloads from old PDS and streams to new PDS
# - UploadBlobsJob: Uploads from local files to new PDS
#
# Error Handling:
# - Missing files: fail with error
# - Upload failure: retry individual blobs
# - Rate limits: longer backoff
# - Overall failure: mark migration as failed
#
# Usage:
#   UploadBlobsJob.perform_later(migration.id)

class UploadBlobsJob < ApplicationJob
  queue_as :migrations

  # Constants
  PARALLEL_BLOBS = 5
  # Per-blob attempts in the parallel pass (2, 4, 8, 16, 32 s of backoff). The
  # target PDS has been seen rejecting ~70% of uploads with 500 for 40 minutes
  # at a stretch; a few quick retries cannot ride that out on their own.
  MAX_RETRIES = 5
  PROGRESS_UPDATE_INTERVAL = 10
  # After the parallel pass, wait this long and retry the leftovers one by one.
  SECOND_PASS_DELAY = 30
  # Blobs still missing after the second pass are retried by RetryFailedBlobsJob
  # this much later (the user is usually waiting for the PLC token anyway).
  AUTO_RETRY_DELAY = 15.minutes

  # Retry configuration
  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform(migration_id)
    migration = Migration.find(migration_id)
    logger.info("Starting blob upload for migration #{migration.token} (DID: #{migration.did})")

    # Idempotency check: Skip if already past this stage
    if migration.status != 'pending_blobs'
      logger.info("Migration #{migration.token} is already at status '#{migration.status}', skipping blob upload")
      return
    end

    # Step 1: Verify local blobs directory exists
    unless migration.downloaded_data_path.present?
      raise "Downloaded data path not set"
    end

    data_dir = Pathname.new(migration.downloaded_data_path)
    blobs_dir = data_dir.join('blobs')

    unless Dir.exist?(blobs_dir)
      raise "Blobs directory not found at: #{blobs_dir}"
    end

    # Step 2: List all local blob files
    blob_files = Dir.glob(blobs_dir.join('*')).select { |f| File.file?(f) }
    logger.info("Found #{blob_files.length} blobs to upload")

    # Step 3: Initialize GoatService and login
    goat = GoatService.new(migration)
    goat.login_new_pds

    # Step 4: Upload all blobs in parallel
    upload_all_blobs(migration, goat, blob_files)

    logger.info("Blob upload completed")

    # Step 5: Advance to next stage
    migration.advance_to_pending_prefs!

  rescue Migration::Aborted => e
    # Cancelled, failed or completed underneath us - stop without retrying
    logger.warn(e.message)

  rescue StandardError => e
    logger.error("Blob upload failed for migration #{migration&.id || migration_id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))

    if migration
      migration.reload
      migration.mark_failed!("Blob upload failed: #{e.message}", error_code: :generic)
    end

    raise
  end

  private

  # Upload all blobs using a thread pool (PARALLEL_BLOBS threads per migration).
  # Every migration runs its own pool independently — no global gating.
  def upload_all_blobs(migration, goat, blob_files)
    total_blobs = blob_files.length
    uploaded_count = 0
    failed_cids = []
    failed_files = []
    total_bytes = 0

    # Thread-safe counters and queue
    mutex = Mutex.new
    queue = Queue.new
    aborted = false # set when the migration is cancelled/failed while uploading

    # Add all blob files to the queue
    blob_files.each_with_index { |blob_file, index| queue << [blob_file, index] }

    # Release the main thread's DB connection before entering the thread pool.
    # It's idle during uploads (just waiting on thread joins) and holding
    # it would waste a pooled connection for the entire duration.
    ActiveRecord::Base.connection_pool.release_connection

    # Create worker threads (thread pool)
    threads = PARALLEL_BLOBS.times.map do
      Thread.new do
        loop do
          break if aborted

          # Get next blob from queue (non-blocking)
          begin
            blob_file, index = queue.pop(true)
          rescue ThreadError
            # Queue is empty, thread can exit
            break
          end

          begin
            cid = File.basename(blob_file)

            # Get file size
            blob_size = File.size(blob_file)

            # Upload blob to new PDS (streamed from disk)
            upload_blob_with_retry(goat, blob_file)

            # Update metrics (thread-safe)
            mutex.synchronize do
              uploaded_count += 1
              total_bytes += blob_size
            end

            logger.info("Uploaded blob #{index + 1}/#{total_blobs}: #{cid} (#{format_bytes(blob_size)})")

            # Update progress periodically.
            # Use with_connection to borrow and return a DB connection immediately.
            if (index + 1) % PROGRESS_UPDATE_INTERVAL == 0
              mutex.synchronize do
                ActiveRecord::Base.connection_pool.with_connection do
                  update_upload_progress(migration, uploaded_count, total_blobs, total_bytes)
                  aborted = true if migration.terminal_in_db?
                end
              end
            end

          rescue StandardError => e
            logger.error("Failed to upload blob #{cid}: #{e.message}")
            mutex.synchronize do
              failed_cids << cid
              failed_files << blob_file
            end
          end
        end
      end
    end

    # Wait for all worker threads to complete
    threads.each(&:join)

    # Final progress update
    update_upload_progress(migration, uploaded_count, total_blobs, total_bytes)

    raise Migration::Aborted, "Migration #{migration.token} was cancelled or failed during blob upload; stopping" if aborted

    # Second, sequential pass for whatever the parallel pass could not upload
    if failed_files.any?
      recovered_files = retry_failed_uploads(migration, goat, failed_files)
      uploaded_count += recovered_files.length
      total_bytes += recovered_files.sum { |f| File.size(f) }
      failed_files -= recovered_files
      failed_cids = failed_files.map { |f| File.basename(f) }
      update_upload_progress(migration, uploaded_count, total_blobs, total_bytes)
    end

    # Log summary
    logger.info("Upload complete: #{uploaded_count}/#{total_blobs} successful")
    logger.info("Total data uploaded: #{format_bytes(total_bytes)}")

    if failed_cids.any?
      logger.warn("Failed to upload #{failed_cids.length} blobs: #{failed_cids.join(', ')}")

      # Save failed uploads to migration metadata. 'failed_blobs' is the key the
      # status page, the retry button and RetryFailedBlobsJob read (the import
      # path always wrote it; this path only wrote 'failed_uploads', so failures
      # here were invisible and migrations completed with missing media).
      migration.merge_progress!(
        'failed_uploads' => failed_cids,
        'failed_blobs' => failed_cids,
        'blobs_auto_retry_scheduled_at' => Time.current.iso8601
      )

      # Automatic retry once the PDS has had time to recover (first of up to
      # three background passes, see RetryFailedBlobsJob::AUTO_RETRY_DELAYS);
      # the user can also trigger one from the status page at any time.
      RetryFailedBlobsJob.set(wait: AUTO_RETRY_DELAY).perform_later(migration.id, failed_cids, 1)
      logger.info("Scheduled automatic retry of #{failed_cids.length} blobs in #{AUTO_RETRY_DELAY.inspect}")

      # Write failed uploads manifest for visibility
      if migration.downloaded_data_path.present?
        manifest_path = File.join(migration.downloaded_data_path, 'FAILED_BLOB_UPLOADS.txt')
        File.write(manifest_path, <<~MANIFEST)
          FAILED BLOB UPLOADS REPORT
          ==========================

          Migration: #{migration.token}
          DID: #{migration.did}
          Date: #{Time.current.iso8601}

          Total blobs: #{total_blobs}
          Successfully uploaded: #{uploaded_count}
          Failed to upload: #{failed_cids.length}

          FAILED BLOB CIDs:
          #{failed_cids.map { |cid| "  - #{cid}" }.join("\n")}

          These blobs were available locally but failed to upload to the new PDS
          due to network errors or timeouts. You may need to re-upload these manually.
        MANIFEST

        logger.info("Wrote failed uploads manifest to #{manifest_path}")
      end
    end
  end

  # Upload blob with retry logic
  def upload_blob_with_retry(goat, blob_file, attempt = 1)
    goat.upload_blob(blob_file)
  rescue GoatService::RateLimitError => e
    if attempt < MAX_RETRIES
      backoff = 2 ** (attempt + 2) # 8s, 16s, 32s, 64s, 128s
      logger.warn("Rate limit hit uploading blob (attempt #{attempt}/#{MAX_RETRIES}): #{blob_file} - retrying in #{backoff}s")
      pause(backoff)
      upload_blob_with_retry(goat, blob_file, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_RETRIES} rate-limit retries: #{blob_file}")
      raise
    end
  rescue GoatService::NetworkError, GoatService::TimeoutError => e
    if attempt < MAX_RETRIES
      logger.warn("Blob upload failed (attempt #{attempt}/#{MAX_RETRIES}): #{blob_file} - #{e.message}")
      pause(2 ** attempt) # 2s, 4s, 8s, 16s, 32s
      upload_blob_with_retry(goat, blob_file, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_RETRIES} attempts: #{blob_file}")
      raise
    end
  end

  # Sequential retry of the blobs the parallel pass could not upload, after a
  # breather for the target PDS. Returns the files that succeeded this time.
  def retry_failed_uploads(migration, goat, failed_files)
    logger.warn("#{failed_files.length} blobs failed in the parallel pass; retrying one at a time after #{SECOND_PASS_DELAY}s")
    pause(SECOND_PASS_DELAY)

    recovered = []
    failed_files.each do |blob_file|
      break if migration.terminal_in_db?

      begin
        upload_blob_with_retry(goat, blob_file)
        recovered << blob_file
        logger.info("Recovered blob on second pass: #{File.basename(blob_file)}")
      rescue StandardError => e
        logger.error("Second pass failed for blob #{File.basename(blob_file)}: #{e.message}")
      end
    end

    logger.info("Second pass recovered #{recovered.length}/#{failed_files.length} blobs")
    recovered
  end

  # All waits go through here so specs can stub them
  def pause(seconds)
    sleep(seconds)
  end

  # Update upload progress in database
  def update_upload_progress(migration, uploaded, total, bytes_uploaded)
    # Write the upload-specific keys AND the generic keys the status page reads
    # (Migration#blob_upload_percentage, MigrationsController#calculate_blob_statistics
    # use blobs_completed / bytes_transferred). Without them the progress bar sat
    # at 40% and the counters at 0 for the whole upload.
    # Atomic JSONB merge: never writes back a stale copy of progress_data.
    migration.merge_progress!(
      'blobs_uploaded' => uploaded,
      'blobs_completed' => uploaded,
      'blobs_total' => total,
      'bytes_uploaded' => bytes_uploaded,
      'bytes_transferred' => bytes_uploaded,
      'last_progress_update' => Time.current.iso8601
    )

    logger.debug("Upload progress: #{uploaded}/#{total} blobs (#{format_bytes(bytes_uploaded)})")
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
