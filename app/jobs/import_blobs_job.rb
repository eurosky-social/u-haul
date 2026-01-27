# ImportBlobsJob - Memory-intensive blob transfer job for Eurosky migration
#
# This is the most critical and resource-intensive job in the migration pipeline.
# It handles downloading blobs from the old PDS and uploading them to the new PDS
# with strict memory management and concurrency control.
#
# Critical Features:
# - Concurrency limiting (max 15 migrations in pending_blobs simultaneously)
# - Sequential blob processing (never parallel) for memory control
# - Aggressive memory cleanup (GC.start every 50 blobs)
# - Batched progress updates (every 10th blob to reduce DB writes)
# - Individual blob retry with exponential backoff
# - Detailed progress tracking and memory estimation
#
# Flow:
# 1. Check concurrency limit (max 15 pending_blobs migrations)
# 2. If at capacity, re-enqueue with 30s delay and return
# 3. Mark blobs_started_at timestamp
# 4. List all blobs with pagination (cursor-based)
# 5. Estimate memory usage via MemoryEstimatorService
# 6. Update migration with blob_count and estimated_memory_mb
# 7. Process blobs SEQUENTIALLY:
#    - Download blob to tmp/goat/{did}/blobs/{cid}
#    - Upload to new PDS
#    - Update progress every 10th blob
#    - Delete local blob file immediately
#    - Log each transfer (CID + size)
#    - Call GC.start after every 50 blobs
# 8. Mark blobs_completed_at timestamp
# 9. Advance to pending_prefs status
#
# Memory Optimization:
# - Sequential processing only (no parallel downloads/uploads)
# - Immediate cleanup after each upload
# - Progress updates batched (every 10 blobs)
# - Explicit GC every 50 blobs
# - Track total bytes transferred
#
# Error Handling:
# - Network errors: retry individual blob (max 3 attempts)
# - Overall job failure: mark migration as failed
# - Log warnings for individual blob failures, don't fail entire job
#
# Usage:
#   ImportBlobsJob.perform_later(migration)
#
# ActiveJob/Sidekiq Configuration:
#   queue: :migrations
#   retry: 3

class ImportBlobsJob < ApplicationJob
  queue_as :migrations

  # Constants
  MAX_CONCURRENT_BLOB_MIGRATIONS = 15
  REQUEUE_DELAY = 30.seconds
  MAX_BLOB_RETRIES = 3
  PROGRESS_UPDATE_INTERVAL = 10 # Update progress every N blobs
  GC_INTERVAL = 50 # Run garbage collection every N blobs

  # Retry configuration (3 attempts with exponential backoff)
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(migration)
    logger.info("Starting blob import for migration #{migration.token} (DID: #{migration.did})")

    # Step 1: Check concurrency limit
    if at_concurrency_limit?
      logger.info("Concurrency limit reached (#{MAX_CONCURRENT_BLOB_MIGRATIONS}), re-enqueuing in #{REQUEUE_DELAY}s")
      self.class.set(wait: REQUEUE_DELAY).perform_later(migration)
      return
    end

    # Step 2: Mark blobs_started_at
    mark_blobs_started(migration)

    # Step 3: Initialize GoatService
    goat = GoatService.new(migration)

    # Step 4: Login to old PDS
    goat.login_old_pds

    # Step 5: List all blobs with pagination
    all_blobs = collect_all_blobs(goat)

    logger.info("Found #{all_blobs.length} total blobs to transfer")

    # Step 6: Estimate memory and update migration
    estimate_and_update_memory(migration, all_blobs)

    # Step 7: Process blobs sequentially
    process_blobs_sequentially(migration, goat, all_blobs)

    # Step 8: Mark blobs_completed_at
    mark_blobs_completed(migration)

    logger.info("Blob import completed for migration #{migration.token}")

    # Step 9: Advance to next stage
    migration.advance_to_pending_prefs!

  rescue StandardError => e
    logger.error("Blob import failed for migration #{migration.id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))

    migration.reload
    migration.mark_failed!("Blob import failed: #{e.message}")

    raise
  end

  private

  # Check if we're at the concurrency limit for blob migrations
  def at_concurrency_limit?
    current_count = Migration.where(status: :pending_blobs).count
    current_count >= MAX_CONCURRENT_BLOB_MIGRATIONS
  end

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

  # Estimate memory usage and update migration record
  def estimate_and_update_memory(migration, blobs)
    # Build blob list with size estimates for MemoryEstimatorService
    blob_list = blobs.map do |cid|
      # We don't have size info yet, so service will use averages
      { cid: cid }
    end

    estimated_mb = MemoryEstimatorService.estimate(blob_list)

    migration.update!(
      estimated_memory_mb: estimated_mb,
      progress_data: migration.progress_data.merge(
        'blob_count' => blobs.length,
        'estimated_memory_mb' => estimated_mb
      )
    )

    logger.info("Estimated memory: #{estimated_mb} MB for #{blobs.length} blobs")
  end

  # Process all blobs sequentially with memory optimization
  def process_blobs_sequentially(migration, goat, blobs)
    # Login to new PDS for uploads
    goat.login_new_pds

    total_bytes_transferred = 0
    successful_count = 0
    failed_cids = []

    blobs.each_with_index do |cid, index|
      begin
        # Download blob from old PDS
        blob_path = download_blob_with_retry(goat, cid)

        # Get file size for tracking
        blob_size = File.size(blob_path)

        # Upload blob to new PDS
        upload_blob_with_retry(goat, blob_path)

        # Update metrics
        total_bytes_transferred += blob_size
        successful_count += 1

        # Log transfer
        logger.info("Transferred blob #{index + 1}/#{blobs.length}: #{cid} (#{format_bytes(blob_size)})")

        # Delete local file immediately
        FileUtils.rm_f(blob_path)

        # Update progress every PROGRESS_UPDATE_INTERVAL blobs
        if (index + 1) % PROGRESS_UPDATE_INTERVAL == 0
          update_blob_progress(migration, successful_count, blobs.length, total_bytes_transferred)
        end

        # Run garbage collection every GC_INTERVAL blobs
        if (index + 1) % GC_INTERVAL == 0
          logger.debug("Running garbage collection after #{index + 1} blobs")
          GC.start
        end

      rescue StandardError => e
        logger.error("Failed to transfer blob #{cid}: #{e.message}")
        failed_cids << cid

        # Continue with next blob - don't fail entire job for individual blob
        next
      end
    end

    # Final progress update
    update_blob_progress(migration, successful_count, blobs.length, total_bytes_transferred)

    # Log summary
    logger.info("Blob transfer complete: #{successful_count}/#{blobs.length} successful")
    logger.info("Total data transferred: #{format_bytes(total_bytes_transferred)}")

    if failed_cids.any?
      logger.warn("Failed to transfer #{failed_cids.length} blobs: #{failed_cids.join(', ')}")
      migration.progress_data ||= {}
      migration.progress_data['failed_blobs'] = failed_cids
      migration.save!
    end

    # Final GC
    GC.start
  end

  # Download blob with retry logic
  def download_blob_with_retry(goat, cid, attempt = 1)
    goat.download_blob(cid)
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
    migration.progress_data ||= {}
    migration.progress_data['blobs_completed'] = completed
    migration.progress_data['blobs_total'] = total
    migration.progress_data['bytes_transferred'] = bytes_transferred
    migration.progress_data['last_progress_update'] = Time.current.iso8601
    migration.save!

    logger.debug("Progress: #{completed}/#{total} blobs (#{format_bytes(bytes_transferred)})")
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
