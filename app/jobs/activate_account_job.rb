# ActivateAccountJob - Final step of account migration
#
# This job completes the migration by:
#   1. Activating the account on the new PDS
#   2. Deactivating the account on the old PDS
#   3. Marking the migration as complete
#
# Status Flow:
#   pending_activation -> completed
#
# What This Job Does:
#   1. Activates account on new PDS (makes it live)
#   2. Deactivates account on old PDS (prevents further use)
#   3. Updates progress timestamps
#   4. Marks migration as complete
#
# Retries: 3 times (activation is idempotent)
# Queue: :critical (highest priority - finish the migration)
#
# Error Handling:
#   - Retries on transient network failures
#   - Updates migration.last_error on failure
#   - If deactivation of old PDS fails, still marks migration complete
#     (account is live on new PDS, which is the important part)
#
# Progress Tracking:
#   Updates progress_data with:
#   - account_activated_at: timestamp (new PDS)
#   - account_deactivated_at: timestamp (old PDS)
#   - completed_at: timestamp (migration complete)
#
# Note: After this job completes, the user's account is fully migrated
# and operational on the new PDS. The old PDS account is deactivated
# but data remains there (could be deleted later if desired).

class ActivateAccountJob < ApplicationJob
  queue_as :critical
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(migration)
    Rails.logger.info("Starting account activation for migration #{migration.token} (#{migration.did})")

    # Initialize GoatService
    service = GoatService.new(migration)

    # Step 1: Activate account on new PDS
    Rails.logger.info("Activating account on new PDS: #{migration.new_pds_host}")
    service.activate_account

    # Update progress
    migration.progress_data['account_activated_at'] = Time.current.iso8601
    migration.save!

    Rails.logger.info("Account activated on new PDS for migration #{migration.token}")

    # Step 2: Deactivate account on old PDS
    begin
      Rails.logger.info("Deactivating account on old PDS: #{migration.old_pds_host}")
      service.deactivate_account

      # Update progress
      migration.progress_data['account_deactivated_at'] = Time.current.iso8601
      migration.save!

      Rails.logger.info("Account deactivated on old PDS for migration #{migration.token}")
    rescue StandardError => e
      # Log the error but don't fail the migration
      # The new PDS is active, which is what matters most
      Rails.logger.warn("Failed to deactivate account on old PDS for migration #{migration.token}: #{e.message}")
      Rails.logger.warn("Migration will proceed as complete - new PDS is active")

      # Update progress with error note
      migration.progress_data['old_pds_deactivation_error'] = e.message
      migration.save!
    end

    # Step 3: Mark migration as complete
    Rails.logger.info("Marking migration complete for #{migration.token}")
    migration.progress_data['completed_at'] = Time.current.iso8601
    migration.save!

    migration.mark_complete!

    Rails.logger.info("=" * 80)
    Rails.logger.info("MIGRATION COMPLETE")
    Rails.logger.info("Token: #{migration.token}")
    Rails.logger.info("DID: #{migration.did}")
    Rails.logger.info("Old Handle: #{migration.old_handle} @ #{migration.old_pds_host}")
    Rails.logger.info("New Handle: #{migration.new_handle} @ #{migration.new_pds_host}")
    Rails.logger.info("Account is now live on new PDS")
    Rails.logger.info("=" * 80)

  rescue GoatService::AuthenticationError => e
    Rails.logger.error("Authentication failed for migration #{migration.token}: #{e.message}")
    migration.mark_failed!("Account activation failed: Authentication error - #{e.message}")
    raise
  rescue GoatService::NetworkError => e
    Rails.logger.error("Network error for migration #{migration.token}: #{e.message}")
    migration.mark_failed!("Account activation failed: Network error - #{e.message}")
    raise
  rescue GoatService::GoatError => e
    Rails.logger.error("Goat error for migration #{migration.token}: #{e.message}")
    migration.mark_failed!("Account activation failed: #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.error("Unexpected error for migration #{migration.token}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    migration.mark_failed!("Account activation failed: #{e.message}")
    raise
  end
end
