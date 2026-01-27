# ImportRepoJob - Repository export/import step of PDS migration
#
# This job exports the user's repository (posts, profile, etc.) from the old PDS
# as a CAR file and imports it into the new PDS. This preserves all content.
#
# Flow:
# 1. Find migration by ID
# 2. Create GoatService instance
# 3. Export repository from old PDS (CAR file)
# 4. Log in to new PDS
# 5. Import repository to new PDS
# 6. Update progress_data with timestamps
# 7. Advance to pending_blobs status
#
# Error Handling:
# - Retries up to 3 times on failure
# - Marks migration as failed if all retries exhausted
# - Handles GoatService exceptions (AuthenticationError, NetworkError, GoatError)
# - Logs all operations for debugging
# - Cleans up temporary CAR files on completion
#
# Queue: migrations (priority 2)
# Retry: 3 attempts with exponential backoff

class ImportRepoJob < ApplicationJob
  queue_as :migrations
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(migration_id)
    migration = Migration.find(migration_id)

    Rails.logger.info("[ImportRepoJob] Starting for migration #{migration.token} (DID: #{migration.did})")

    # Update timestamp
    migration.progress_data ||= {}
    migration.progress_data['repo_import_started_at'] = Time.current.iso8601
    migration.save!

    # Create GoatService instance
    goat = GoatService.new(migration)

    # Step 1: Export repository from old PDS
    Rails.logger.info("[ImportRepoJob] Exporting repository from old PDS: #{migration.old_pds_host}")
    car_path = goat.export_repo

    # Log CAR file size
    car_size_mb = File.size(car_path).to_f / (1024 * 1024)
    Rails.logger.info("[ImportRepoJob] Repository exported: #{car_size_mb.round(2)} MB")

    migration.progress_data['repo_car_path'] = car_path
    migration.progress_data['repo_car_size_mb'] = car_size_mb.round(2)
    migration.progress_data['repo_exported_at'] = Time.current.iso8601
    migration.save!

    # Step 2: Import repository to new PDS
    Rails.logger.info("[ImportRepoJob] Importing repository to new PDS: #{migration.new_pds_host}")
    goat.import_repo(car_path)

    # Step 3: Update progress data
    migration.progress_data['repo_imported_at'] = Time.current.iso8601
    migration.save!

    Rails.logger.info("[ImportRepoJob] Repository imported successfully")

    # Step 4: Clean up CAR file (optional - keep for debugging if needed)
    # File.delete(car_path) if File.exist?(car_path)

    # Step 5: Advance to next stage
    Rails.logger.info("[ImportRepoJob] Advancing to pending_blobs")
    migration.advance_to_pending_blobs!

    Rails.logger.info("[ImportRepoJob] Completed successfully for migration #{migration.token}")

  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[ImportRepoJob] Migration not found: #{migration_id}")
    # Don't retry if migration doesn't exist

  rescue GoatService::AuthenticationError => e
    Rails.logger.error("[ImportRepoJob] Authentication failed for migration #{migration&.token}: #{e.message}")
    handle_error(migration, e)

  rescue GoatService::NetworkError => e
    Rails.logger.error("[ImportRepoJob] Network error for migration #{migration&.token}: #{e.message}")
    handle_error(migration, e)

  rescue GoatService::TimeoutError => e
    Rails.logger.error("[ImportRepoJob] Timeout error for migration #{migration&.token}: #{e.message}")
    handle_error(migration, e)

  rescue GoatService::GoatError => e
    Rails.logger.error("[ImportRepoJob] Goat error for migration #{migration&.token}: #{e.message}")
    handle_error(migration, e)

  rescue StandardError => e
    Rails.logger.error("[ImportRepoJob] Unexpected error for migration #{migration&.token}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    handle_error(migration, e)
  end

  private

  def handle_error(migration, error)
    return unless migration

    # Update retry count
    migration.reload
    current_retry = executions - 1 # executions is 1-based, we need 0-based

    if current_retry >= 2 # 0, 1, 2 = 3 attempts total
      # All retries exhausted, mark as failed
      Rails.logger.error("[ImportRepoJob] All retries exhausted for migration #{migration.token}, marking as failed")
      migration.mark_failed!(error.message)
    else
      # Will retry, just log the error
      Rails.logger.info("[ImportRepoJob] Will retry (attempt #{current_retry + 1}/3) for migration #{migration.token}")
      migration.update(last_error: error.message)
      raise error # Re-raise to trigger ActiveJob retry
    end
  end
end
