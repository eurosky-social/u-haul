# DownloadAllDataJob - Downloads all account data for backup and migration
#
# This job downloads the user's complete account data from the old PDS:
# - Repository (CAR file) - complete repo checkout
# - All blobs (images, videos, etc.) - all attachments
#
# Downloaded data is stored locally and used for:
# 1. Creating backup bundle for user download
# 2. Uploading to new PDS (avoiding double-download)
#
# Flow:
# 1. Create local storage directory for this migration
# 2. Download repository as CAR file
# 3. List all blobs from old PDS
# 4. Download blobs in parallel batches (10 at a time)
# 5. Update progress tracking
# 6. Advance to pending_backup status
#
# Storage Structure:
#   tmp/migrations/{did}/
#   ├── repo.car           (repository export)
#   └── blobs/
#       ├── {cid1}         (blob file)
#       ├── {cid2}
#       └── ...
#
# Memory Management:
# - Parallel downloads (10 concurrent)
# - Progress tracking every 10 blobs
# - Thread-safe counters
#
# Error Handling:
# - Network errors: retry with exponential backoff
# - Rate limits: longer backoff
# - Individual blob failures: log and continue
# - Overall failure: mark migration as failed
#
# Usage:
#   DownloadAllDataJob.perform_later(migration.id)

class DownloadAllDataJob < ApplicationJob
  queue_as :migrations

  # Constants
  PARALLEL_DOWNLOADS = 10
  MAX_RETRIES = 3
  PROGRESS_UPDATE_INTERVAL = 10

  # Retry configuration
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform(migration_id)
    migration = Migration.find(migration_id)
    logger.info("Starting download for migration #{migration.token} (DID: #{migration.did})")

    # Step 1: Create local storage directory
    storage_dir = create_storage_directory(migration)
    migration.update!(downloaded_data_path: storage_dir.to_s)

    # Step 2: Initialize GoatService
    goat = GoatService.new(migration)

    # Step 3: Download repository
    logger.info("Downloading repository...")
    repo_path = download_repository(goat, storage_dir)
    logger.info("Repository downloaded: #{repo_path}")

    # Step 4: List all blobs
    logger.info("Listing blobs...")
    all_blobs = collect_all_blobs(goat)
    logger.info("Found #{all_blobs.length} blobs to download")

    # Update migration with blob count
    migration.progress_data ||= {}
    migration.progress_data['download_progress'] = {
      'total' => all_blobs.length,
      'downloaded' => 0
    }
    migration.save!

    # Step 5: Download all blobs in parallel
    download_all_blobs(migration, goat, all_blobs, storage_dir)

    logger.info("Download completed for migration #{migration.token}")

    # Step 6: Advance to next stage
    migration.advance_to_pending_backup!

  rescue StandardError => e
    logger.error("Download failed for migration #{migration_id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))

    # Only update migration if it still exists
    if migration && Migration.exists?(migration_id)
      migration.reload
      migration.mark_failed!("Download failed: #{e.message}")
    end

    raise
  end

  private

  # Create local storage directory for this migration
  def create_storage_directory(migration)
    # Use DID as directory name (sanitized)
    dir_name = migration.did.gsub(/[^a-z0-9_-]/i, '_')
    storage_dir = Rails.root.join('tmp', 'migrations', dir_name)

    # Clean up any existing directory
    FileUtils.rm_rf(storage_dir) if Dir.exist?(storage_dir)

    # Create fresh directories
    FileUtils.mkdir_p(storage_dir)
    FileUtils.mkdir_p(storage_dir.join('blobs'))

    storage_dir
  end

  # Download repository CAR file
  def download_repository(goat, storage_dir)
    # Export repo from old PDS (returns the path to the created CAR file)
    car_path = goat.export_repo

    # Copy the CAR file to the migration's storage directory
    destination_path = storage_dir.join('repo.car')
    FileUtils.cp(car_path, destination_path)

    logger.info("Copied repository from #{car_path} to #{destination_path}")

    # Return the destination path as a Pathname
    destination_path
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

  # Download all blobs in parallel batches
  def download_all_blobs(migration, goat, blobs, storage_dir)
    total_blobs = blobs.length
    downloaded_count = 0
    failed_cids = []
    total_bytes = 0

    # Thread-safe counters
    mutex = Mutex.new

    # Process blobs in parallel batches
    blobs.each_slice(PARALLEL_DOWNLOADS).with_index do |batch, batch_index|
      threads = batch.map.with_index do |cid, batch_offset|
        Thread.new do
          begin
            index = batch_index * PARALLEL_DOWNLOADS + batch_offset

            # Download blob to local storage
            blob_path = storage_dir.join('blobs', cid)
            download_blob_with_retry(goat, cid, blob_path.to_s)

            # Get file size
            blob_size = File.size(blob_path)

            # Update metrics (thread-safe)
            mutex.synchronize do
              downloaded_count += 1
              total_bytes += blob_size
            end

            logger.info("Downloaded blob #{index + 1}/#{total_blobs}: #{cid} (#{format_bytes(blob_size)})")

          rescue StandardError => e
            logger.error("Failed to download blob #{cid}: #{e.message}")
            mutex.synchronize do
              failed_cids << cid
            end
          end
        end
      end

      # Wait for all threads in this batch to complete
      threads.each(&:join)

      # Update progress after each batch
      update_download_progress(migration, downloaded_count, total_blobs, total_bytes)
    end

    # Log summary
    logger.info("Download complete: #{downloaded_count}/#{total_blobs} successful")
    logger.info("Total data downloaded: #{format_bytes(total_bytes)}")

    if failed_cids.any?
      logger.warn("Failed to download #{failed_cids.length} blobs: #{failed_cids.join(', ')}")
      migration.progress_data ||= {}
      migration.progress_data['failed_downloads'] = failed_cids
      migration.save!
    end
  end

  # Download blob with retry logic
  def download_blob_with_retry(goat, cid, blob_path, attempt = 1)
    url = "#{goat.migration.old_pds_host}/xrpc/com.atproto.sync.getBlob?did=#{goat.migration.did}&cid=#{cid}"

    response = HTTParty.get(
      url,
      timeout: 300,
      headers: {
        'Accept' => 'application/octet-stream'
      }
    )

    unless response.success?
      raise GoatService::NetworkError, "HTTP #{response.code}: #{response.message}"
    end

    # Write blob to file
    File.binwrite(blob_path, response.body)

  rescue GoatService::RateLimitError => e
    if attempt < MAX_RETRIES
      backoff = 2 ** (attempt + 2) # 8s, 16s, 32s
      logger.warn("Rate limit hit downloading blob (attempt #{attempt}/#{MAX_RETRIES}): #{cid} - retrying in #{backoff}s")
      sleep(backoff)
      download_blob_with_retry(goat, cid, blob_path, attempt + 1)
    else
      logger.error("Blob download failed after #{MAX_RETRIES} rate-limit retries: #{cid}")
      raise
    end
  rescue StandardError => e
    if attempt < MAX_RETRIES
      logger.warn("Blob download failed (attempt #{attempt}/#{MAX_RETRIES}): #{cid} - #{e.message}")
      sleep(2 ** attempt) # 2s, 4s, 8s
      download_blob_with_retry(goat, cid, blob_path, attempt + 1)
    else
      logger.error("Blob download failed after #{MAX_RETRIES} attempts: #{cid}")
      raise
    end
  end

  # Update download progress in database
  def update_download_progress(migration, downloaded, total, bytes_downloaded)
    migration.progress_data ||= {}
    migration.progress_data['download_progress'] = {
      'total' => total,
      'downloaded' => downloaded,
      'bytes' => bytes_downloaded,
      'last_update' => Time.current.iso8601
    }
    migration.save!

    logger.debug("Download progress: #{downloaded}/#{total} blobs (#{format_bytes(bytes_downloaded)})")
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
