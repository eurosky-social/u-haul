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
  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  MAX_BLOB_RETRIES = 3

  # Background passes after the blob stage: UploadBlobsJob schedules pass 1
  # (15 minutes later); a pass that still leaves blobs behind schedules the
  # next one with these delays. The target PDS has rejected uploads for up to
  # an hour at a stretch, so a single retry would often land inside the same
  # outage. Manual retries from the status page are unlimited.
  AUTO_RETRY_DELAYS = [1.hour, 4.hours].freeze

  # auto_attempt: nil for a user-triggered retry, 1.. for the background passes
  def perform(migration_id, failed_blob_cids, auto_attempt = nil)
    migration = Migration.find(migration_id)
    logger.info("Retrying #{failed_blob_cids.length} failed blobs for migration #{migration.token}" \
                "#{auto_attempt ? " (automatic pass #{auto_attempt})" : ''}")

    # Scheduled automatically by UploadBlobsJob as well as by the status page;
    # a cancelled/failed migration must not be touched any more.
    if migration.failed?
      logger.info("Migration #{migration.token} is failed or cancelled; not retrying blobs")
      return
    end

    # Initialize GoatService
    goat = GoatService.new(migration)

    # Login to new PDS for uploads
    goat.login_new_pds

    # Measure this pass. Retry passes run against a PDS that already refused
    # these blobs once, so their success rate is the interesting one: it says
    # whether the target recovered or is still bad.
    start_blob_pass(migration, pass: BlobTransferTelemetry::PASS_RETRY, goat: goat)

    # Track results
    successful_cids = []
    still_failed_cids = []

    # Process each failed blob
    failed_blob_cids.each_with_index do |cid, index|
      begin
        logger.info("Retrying blob #{index + 1}/#{failed_blob_cids.length}: #{cid}")

        # Prefer the local copy from the backup bundle (no dependency on the
        # old PDS, which may already be deactivated); otherwise download it
        local_path = local_blob_path(migration, cid)
        blob_path = local_path || download_blob_with_retry(goat, cid)

        # Upload blob to new PDS
        upload_blob_with_retry(goat, blob_path)

        # Cleanup (bundle files are kept for the user's download)
        FileUtils.rm_f(blob_path) unless local_path

        successful_cids << cid
        logger.info("Successfully retried blob: #{cid}")

      rescue StandardError => e
        logger.error("Failed to retry blob #{cid}: #{e.message}")
        still_failed_cids << cid
      end
    end

    # Update migration progress_data (atomic merge - the pipeline may be
    # writing other keys concurrently while the user waits for the PLC token)
    migration.merge_progress!(
      'failed_blobs' => still_failed_cids,
      'failed_uploads' => still_failed_cids,
      'blobs_completed' => migration.progress_data['blobs_completed'].to_i + successful_cids.length,
      'blobs_retry_attempted_at' => Time.current.iso8601,
      'blobs_retry_success_count' => successful_cids.length,
      'blobs_retry_failed_count' => still_failed_cids.length
    )

    # Log summary
    logger.info("Blob retry complete for migration #{migration.token}:")
    logger.info("  Successfully retried: #{successful_cids.length}")
    logger.info("  Still failed: #{still_failed_cids.length}")

    # The user was told in the completion email to keep the new password
    # unchanged until the FINAL mail arrives (a password change revokes the
    # sessions this job needs), so a completed migration must always end in
    # exactly one of the two mails below.
    completed_now = Migration.where(id: migration.id).pick(:status) == 'completed'

    if still_failed_cids.empty?
      if completed_now && migration.progress_data['blobs_transfer_complete_mailed_at'].blank?
        migration.merge_progress!('blobs_transfer_complete_mailed_at' => Time.current.iso8601)
        MigrationMailer.blobs_transfer_complete(migration).deliver_later
        logger.info("All files transferred for completed migration #{migration.token}; final mail queued")
      end
    elsif auto_attempt && auto_attempt <= AUTO_RETRY_DELAYS.length
      # Next background pass, while any are allowed
      delay = AUTO_RETRY_DELAYS[auto_attempt - 1]
      self.class.set(wait: delay).perform_later(migration.id, still_failed_cids, auto_attempt + 1)
      migration.merge_progress!('blobs_auto_retry_scheduled_at' => Time.current.iso8601, 'blobs_auto_retry_exhausted_at' => nil)
      logger.info("Scheduled automatic pass #{auto_attempt + 1} for #{still_failed_cids.length} blobs in #{delay.inspect}")
    elsif auto_attempt
      migration.merge_progress!('blobs_auto_retry_exhausted_at' => Time.current.iso8601)
      logger.warn("Automatic retries exhausted for migration #{migration.token}; #{still_failed_cids.length} blobs remain (manual retry available)")
      if completed_now
        MigrationMailer.blobs_transfer_incomplete(migration, still_failed_cids.length).deliver_later
        logger.info("Incomplete-transfer mail queued for #{migration.token}")
      end
    end

  rescue ActiveRecord::RecordNotFound => e
    logger.error("Migration not found: #{migration_id}")
  rescue StandardError => e
    logger.error("Failed blob retry job failed for migration #{migration_id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))
    raise
  ensure
    finish_blob_pass
  end

  private

  # Path of the blob inside the downloaded backup bundle, if it is there
  def local_blob_path(migration, cid)
    return nil if migration.downloaded_data_path.blank?

    path = File.join(migration.downloaded_data_path, 'blobs', cid)
    File.file?(path) ? path : nil
  end

  # Download blob with retry logic
  def download_blob_with_retry(goat, cid, attempt = 1)
    measure(cid: cid, phase: :download) { goat.download_blob(cid) }
  rescue GoatService::RateLimitError => e
    if attempt < MAX_BLOB_RETRIES
      backoff = 2 ** (attempt + 2) # Longer backoff for rate limits: 8s, 16s, 32s
      logger.warn("Rate limit hit downloading blob (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{cid} - retrying in #{backoff}s")
      pause(backoff)
      download_blob_with_retry(goat, cid, attempt + 1)
    else
      logger.error("Blob download failed after #{MAX_BLOB_RETRIES} rate-limit retries: #{cid}")
      raise
    end
  rescue GoatService::NetworkError, GoatService::TimeoutError => e
    if attempt < MAX_BLOB_RETRIES
      logger.warn("Blob download failed (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{cid} - #{e.message}")
      pause(2 ** attempt) # Exponential backoff: 2s, 4s, 8s
      download_blob_with_retry(goat, cid, attempt + 1)
    else
      logger.error("Blob download failed after #{MAX_BLOB_RETRIES} attempts: #{cid}")
      raise
    end
  end

  # Upload blob with retry logic
  def upload_blob_with_retry(goat, blob_path, attempt = 1)
    measure(cid: File.basename(blob_path.to_s), bytes: file_size(blob_path)) do
      goat.upload_blob(blob_path)
    end
  rescue GoatService::RateLimitError => e
    if attempt < MAX_BLOB_RETRIES
      backoff = 2 ** (attempt + 2) # Longer backoff for rate limits: 8s, 16s, 32s
      logger.warn("Rate limit hit uploading blob (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{blob_path} - retrying in #{backoff}s")
      pause(backoff)
      upload_blob_with_retry(goat, blob_path, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_BLOB_RETRIES} rate-limit retries: #{blob_path}")
      raise
    end
  rescue GoatService::NetworkError, GoatService::TimeoutError => e
    if attempt < MAX_BLOB_RETRIES
      logger.warn("Blob upload failed (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{blob_path} - #{e.message}")
      pause(2 ** attempt) # Exponential backoff: 2s, 4s, 8s
      upload_blob_with_retry(goat, blob_path, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_BLOB_RETRIES} attempts: #{blob_path}")
      raise
    end
  end

  # All waits go through here so specs can stub them
  def pause(seconds)
    sleep(seconds)
  end
end
