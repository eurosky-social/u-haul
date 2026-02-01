# UploadRepoJob - Uploads repository from local file to new PDS
#
# This job uploads the repository CAR file that was previously downloaded
# by DownloadAllDataJob. It's used when backup is enabled to avoid
# re-downloading the repository.
#
# Flow:
# 1. Verify local repo file exists
# 2. Login to new PDS
# 3. Upload repo CAR file using importRepo API
# 4. Verify upload success
# 5. Advance to pending_blobs status
#
# Differences from ImportRepoJob:
# - ImportRepoJob: Downloads from old PDS and streams to new PDS
# - UploadRepoJob: Uploads from local file to new PDS
#
# Error Handling:
# - Missing file: fail with error
# - Upload failure: retry with exponential backoff
# - Authentication failure: fail immediately
# - Overall failure: mark migration as failed
#
# Usage:
#   UploadRepoJob.perform_later(migration.id)

class UploadRepoJob < ApplicationJob
  queue_as :migrations

  # Retry configuration
  # Use polynomially_longer for proper exponential backoff (2s, 8s, 18s, 32s, 50s)
  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  # Special handling for timeout errors - retry more aggressively
  retry_on GoatService::NetworkError, wait: :polynomially_longer, attempts: 7

  def perform(migration_id)
    migration = Migration.find(migration_id)
    logger.info("Starting repo upload for migration #{migration.token} (DID: #{migration.did})")

    # Idempotency check: Skip if already past this stage
    if migration.status != 'pending_repo'
      logger.info("Migration #{migration.token} is already at status '#{migration.status}', skipping repo upload")
      return
    end

    # Step 1: Verify local file exists
    unless migration.downloaded_data_path.present?
      raise "Downloaded data path not set"
    end

    data_dir = Pathname.new(migration.downloaded_data_path)
    repo_path = data_dir.join('repo.car')

    unless File.exist?(repo_path)
      raise "Repository file not found at: #{repo_path}"
    end

    logger.info("Found local repository file: #{repo_path} (#{format_bytes(File.size(repo_path))})")

    # Step 2: Initialize GoatService and login
    goat = GoatService.new(migration)
    goat.login_new_pds

    # Step 3: Upload repository
    logger.info("Uploading repository to new PDS...")
    goat.import_repo(repo_path.to_s)

    logger.info("Repository upload completed")

    # Step 4: Advance to next stage
    migration.advance_to_pending_blobs!

  rescue StandardError => e
    logger.error("Repo upload failed for migration #{migration&.id || migration_id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))

    # Update retry count and last error
    if migration
      migration.reload
      current_retry = executions - 1 # executions is 1-based, we need 0-based

      # Update last error for visibility
      migration.update(last_error: "Upload attempt #{current_retry + 1}: #{e.message}")

      # Check if we've exhausted all retries
      max_attempts = if e.is_a?(GoatService::NetworkError)
        7
      elsif e.is_a?(GoatService::RateLimitError)
        5
      else
        5
      end

      if current_retry >= max_attempts - 1
        # All retries exhausted, mark as failed
        logger.error("[UploadRepoJob] All retries exhausted for migration #{migration.token}, marking as failed")
        migration.mark_failed!("Repo upload failed after #{max_attempts} attempts: #{e.message}")
      else
        # Will retry, just log
        logger.warn("[UploadRepoJob] Will retry (attempt #{current_retry + 1}/#{max_attempts}) for migration #{migration.token}")
      end
    end

    raise # Re-raise to trigger ActiveJob retry
  end

  private

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
