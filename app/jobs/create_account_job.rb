# CreateAccountJob - First step of PDS migration
#
# This job creates a deactivated account on the new PDS with the user's existing DID.
# It's the first step in the migration pipeline after the migration record is created.
#
# Flow:
# 1. Find migration by ID
# 2. Create GoatService instance
# 3. Log in to old PDS (to authenticate)
# 4. Get service auth token from old PDS for new PDS
# 5. Create deactivated account on new PDS with existing DID
# 6. Update migration status to pending_repo
# 7. Advance to ImportRepoJob
#
# Error Handling:
# - Retries up to 3 times on failure
# - Marks migration as failed if all retries exhausted
# - Handles GoatService exceptions (AuthenticationError, NetworkError, GoatError)
# - Logs all operations for debugging
#
# Queue: migrations (priority 2)
# Retry: 3 attempts with exponential backoff

class CreateAccountJob < ApplicationJob
  queue_as :migrations
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  # Special handling for rate-limiting errors with longer backoff
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  # Don't retry account exists errors - they require manual intervention
  discard_on GoatService::AccountExistsError

  def perform(migration_id)
    migration = Migration.find(migration_id)

    Rails.logger.info("[CreateAccountJob] Starting for migration #{migration.token} (DID: #{migration.did})")

    # Idempotency check: Skip if already past this stage
    unless ['pending_account', 'backup_ready'].include?(migration.status)
      Rails.logger.info("[CreateAccountJob] Migration #{migration.token} is already at status '#{migration.status}', skipping account creation")
      return
    end

    # Update timestamp
    migration.progress_data ||= {}
    migration.progress_data['account_creation_started_at'] = Time.current.iso8601
    migration.save!

    # Create GoatService instance
    goat = GoatService.new(migration)

    # Step 1: Login to old PDS
    Rails.logger.info("[CreateAccountJob] Logging in to old PDS: #{migration.old_pds_host}")
    goat.login_old_pds

    # Step 2: Get service auth token for new PDS
    Rails.logger.info("[CreateAccountJob] Getting service auth token for new PDS")
    new_pds_did = goat.send(:get_new_pds_service_did)
    service_auth_token = goat.get_service_auth_token(new_pds_did)

    # Step 3: Create account on new PDS with existing DID
    Rails.logger.info("[CreateAccountJob] Creating deactivated account on new PDS: #{migration.new_pds_host}")
    goat.create_account_on_new_pds(service_auth_token)

    # Step 4: Update progress data
    migration.progress_data['account_created_at'] = Time.current.iso8601
    migration.progress_data['new_pds_did'] = new_pds_did
    migration.save!

    # Step 5: Advance to next stage
    Rails.logger.info("[CreateAccountJob] Account created successfully, advancing to pending_repo")
    migration.advance_to_pending_repo!

    Rails.logger.info("[CreateAccountJob] Completed successfully for migration #{migration.token}")

  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[CreateAccountJob] Migration not found: #{migration_id}")
    # Don't retry if migration doesn't exist

  rescue GoatService::RateLimitError => e
    Rails.logger.warn("[CreateAccountJob] Rate limit hit for migration #{migration&.token}: #{e.message}")
    Rails.logger.warn("[CreateAccountJob] Will retry with exponential backoff")
    migration&.update(last_error: "Rate limit: #{e.message}")
    raise  # Re-raise to trigger ActiveJob retry with polynomially_longer backoff

  rescue GoatService::AuthenticationError => e
    Rails.logger.error("[CreateAccountJob] Authentication failed for migration #{migration&.token}: #{e.message}")
    handle_error(migration, e)

  rescue GoatService::NetworkError => e
    Rails.logger.error("[CreateAccountJob] Network error for migration #{migration&.token}: #{e.message}")
    handle_error(migration, e)

  rescue GoatService::AccountExistsError => e
    Rails.logger.error("[CreateAccountJob] Account exists error for migration #{migration&.token}: #{e.message}")
    # This is a special case - account already exists (likely from failed previous migration)
    # Mark as failed with specific instructions for manual cleanup
    if migration
      migration.mark_failed!(
        "Account already exists on target PDS. This is likely from a previous failed migration attempt. " \
        "To resolve: 1) Clean up orphaned account: scripts/cleanup_orphaned_account_db.sh #{migration.did} " \
        "2) Reset migration: docker compose exec web bundle exec rake 'migration:reset_migration[#{migration.token}]'"
      )
    end
    # Re-raise to trigger discard_on (prevents subsequent jobs from running)
    raise

  rescue GoatService::GoatError => e
    Rails.logger.error("[CreateAccountJob] Goat error for migration #{migration&.token}: #{e.message}")
    handle_error(migration, e)

  rescue StandardError => e
    Rails.logger.error("[CreateAccountJob] Unexpected error for migration #{migration&.token}: #{e.message}")
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
      Rails.logger.error("[CreateAccountJob] All retries exhausted for migration #{migration.token}, marking as failed")
      migration.mark_failed!(error.message)
    else
      # Will retry, just log the error
      Rails.logger.info("[CreateAccountJob] Will retry (attempt #{current_retry + 1}/3) for migration #{migration.token}")
      migration.update(last_error: error.message)
      raise error # Re-raise to trigger ActiveJob retry
    end
  end
end
