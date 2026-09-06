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
# Note: The rotation key was already generated and included in the PLC
# operation by UpdatePlcJob, so no separate PLC operation is needed here.
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
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  # Special handling for rate-limiting errors with longer backoff
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform(migration_id)
    migration = Migration.find(migration_id)
    Rails.logger.info("Starting account activation for migration #{migration.token} (#{migration.did})")

    # Idempotency check: Skip if already past this stage
    if migration.status != 'pending_activation'
      Rails.logger.info("Migration #{migration.token} is already at status '#{migration.status}', skipping account activation")
      return
    end

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

    # Step 2.1: Clear old PDS tokens (no longer needed after deactivation)
    Rails.logger.info("Clearing old PDS tokens for migration #{migration.token}")
    migration.clear_old_pds_tokens!

    # Note: Rotation key was generated and included in the PLC operation by UpdatePlcJob.
    # The user's rotation key is already in the DID document with highest priority,
    # so no additional PLC operation is needed here.
    if migration.progress_data['rotation_key_public'].present?
      Rails.logger.info("Rotation key already in PLC from UpdatePlcJob (#{migration.progress_data['rotation_key_public']})")
    else
      Rails.logger.warn("No rotation key found in progress data — key was not included in PLC operation")
    end

    # Step 3: Mark migration as complete
    Rails.logger.info("Marking migration complete for #{migration.token}")
    migration.progress_data['completed_at'] = Time.current.iso8601
    migration.save!

    migration.mark_complete!

    # Step 4: Send completion email with new account password and backup info
    # This email is the user's permanent record since we'll delete the migration soon
    # The password is included now (not earlier) so the user only gets it when the account is ready
    Rails.logger.info("Sending migration completion email to #{migration.email}")
    begin
      new_account_password = migration.password  # Decrypt from DB before clearing
      MigrationMailer.migration_completed(migration, new_account_password).deliver_later
      Rails.logger.info("Completion email queued successfully (includes new account password)")
    rescue StandardError => e
      Rails.logger.error("Failed to send completion email: #{e.message}")
      # Don't fail migration if email fails
    end

    # Step 5: SECURITY - Clear encrypted credentials after successful migration
    # Passwords and tokens are no longer needed after migration completes
    Rails.logger.info("Clearing encrypted credentials for security")
    migration.clear_credentials!
    Rails.logger.info("Credentials successfully cleared for migration #{migration.token}")

    # Step 6: Clear non-essential data from the migration record
    # Keep only what the user needs: email, rotation key, backup, handles, status
    Rails.logger.info("Clearing non-essential data from migration record")
    migration.clear_non_essential_data!

    # Step 7: Schedule migration record deletion for GDPR compliance
    # Give user 2 days to view status page, download backup, copy rotation key
    # User can also manually delete via the "Delete my data" button on the status page
    Rails.logger.info("Scheduling migration record deletion in 2 days (GDPR compliance)")
    # Files the blob stage could not transfer: the completion email told the
    # user to wait for a FINAL mail before changing the password. Make sure a
    # background pass runs after completion so that mail (or the "incomplete"
    # one) is actually sent - unless a chain from the blob stage is still
    # pending, which will notice the completed status itself.
    missing_blobs = migration.progress_data['failed_blobs'] || []
    if missing_blobs.any? && (migration.progress_data['blobs_auto_retry_exhausted_at'].present? || migration.progress_data['blobs_auto_retry_scheduled_at'].blank?)
      RetryFailedBlobsJob.set(wait: 15.minutes).perform_later(migration.id, missing_blobs, 1)
      migration.merge_progress!('blobs_auto_retry_scheduled_at' => Time.current.iso8601, 'blobs_auto_retry_exhausted_at' => nil)
      Rails.logger.info("Scheduled background retry for #{missing_blobs.length} missing blobs after completion of #{migration.token}")
    end

    DeleteMigrationJob.set(wait: 2.days).perform_later(migration.id)

    Rails.logger.info("=" * 80)
    Rails.logger.info("MIGRATION COMPLETE")
    Rails.logger.info("Token: #{migration.token}")
    Rails.logger.info("DID: #{migration.did}")
    Rails.logger.info("Old Handle: #{migration.old_handle} @ #{migration.old_pds_host}")
    Rails.logger.info("New Handle: #{migration.new_handle} @ #{migration.new_pds_host}")
    Rails.logger.info("Account is now live on new PDS")
    if migration.progress_data['rotation_key_public']
      Rails.logger.info("Rotation key in PLC: #{migration.progress_data['rotation_key_public']}")
    end
    Rails.logger.info("Completion email sent to: #{migration.email}")
    Rails.logger.info("Migration record will be auto-deleted in 2 days (or earlier via user action)")
    Rails.logger.info("=" * 80)

  rescue Migration::Aborted => e
    # Cancelled, failed or completed underneath us - stop without retrying
    Rails.logger.warn(e.message)

  rescue GoatService::RateLimitError => e
    Rails.logger.warn("Rate limit hit for migration #{migration.token}: #{e.message}")
    Rails.logger.warn("Will retry with exponential backoff")
    migration.update(last_error: "Rate limit: #{e.message}")
    raise  # Re-raise to trigger ActiveJob retry with polynomially_longer backoff

  rescue GoatService::AuthenticationError => e
    Rails.logger.error("Authentication failed for migration #{migration.token}: #{e.message}")
    migration.mark_failed!("Account activation failed: Authentication error - #{e.message}", error_code: :authentication)
    raise
  rescue GoatService::NetworkError => e
    Rails.logger.error("Network error for migration #{migration.token}: #{e.message}")
    migration.mark_failed!("Account activation failed: Network error - #{e.message}", error_code: :network)
    raise
  rescue GoatService::GoatError => e
    Rails.logger.error("Goat error for migration #{migration.token}: #{e.message}")
    migration.mark_failed!("Account activation failed: #{e.message}", error_code: :generic)
    raise
  rescue StandardError => e
    Rails.logger.error("Unexpected error for migration #{migration&.token || migration_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    migration&.mark_failed!("Account activation failed: #{e.message}", error_code: :generic)
    raise
  end
end
