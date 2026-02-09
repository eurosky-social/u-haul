# RetryFailedBlobsJob - Retry specific blobs that failed during migration
#
# This job allows users to retry only the blobs that failed during the
# initial ImportBlobsJob, without re-running the entire migration.
#
# Flow:
# 1. Receives migration ID and list of failed blob CIDs
# 2. Logs in to new PDS
# 3. Downloads each failed blob from old PDS
# 4. Uploads each blob to new PDS
# 5. Updates progress_data to remove successfully retried blobs
# 6. Reports final success/failure count
#
# Queue: :migrations
# Retry: 3 attempts

class RetryFailedBlobsJob < ApplicationJob
  queue_as :migrations
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  MAX_BLOB_RETRIES = 3

  def perform(migration_id, failed_blob_cids)
    migration = Migration.find(migration_id)
    logger.info("Retrying #{failed_blob_cids.length} failed blobs for migration #{migration.token}")

    # Initialize GoatService
    goat = GoatService.new(migration)

    # Login to new PDS for uploads
    goat.login_new_pds

    # Track results
    successful_cids = []
    still_failed_cids = []

    # Process each failed blob
    failed_blob_cids.each_with_index do |cid, index|
      begin
        logger.info("Retrying blob #{index + 1}/#{failed_blob_cids.length}: #{cid}")

        # Download blob from old PDS
        blob_path = download_blob_with_retry(goat, cid)

        # Upload blob to new PDS
        upload_blob_with_retry(goat, blob_path)

        # Cleanup
        FileUtils.rm_f(blob_path)

        successful_cids << cid
        logger.info("Successfully retried blob: #{cid}")

      rescue StandardError => e
        logger.error("Failed to retry blob #{cid}: #{e.message}")
        still_failed_cids << cid
      end
    end

    # Update migration progress_data
    migration.progress_data ||= {}
    migration.progress_data['failed_blobs'] = still_failed_cids
    migration.progress_data['blobs_retry_attempted_at'] = Time.current.iso8601
    migration.progress_data['blobs_retry_success_count'] = successful_cids.length
    migration.progress_data['blobs_retry_failed_count'] = still_failed_cids.length
    migration.save!

    # Log summary
    logger.info("Blob retry complete for migration #{migration.token}:")
    logger.info("  Successfully retried: #{successful_cids.length}")
    logger.info("  Still failed: #{still_failed_cids.length}")

    # Send notification email if configured
    if successful_cids.any?
      begin
        MigrationMailer.failed_blobs_retry_complete(migration, successful_cids.length, still_failed_cids.length).deliver_later
      rescue => e
        logger.error("Failed to send retry completion email: #{e.message}")
      end
    end

  rescue ActiveRecord::RecordNotFound => e
    logger.error("Migration not found: #{migration_id}")
  rescue StandardError => e
    logger.error("Failed blob retry job failed for migration #{migration_id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))
    raise
  end

  private

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
end
