# ActivateAccountJob - Final step of account migration
#
# This job completes the migration by:
#   1. Activating the account on the new PDS
#   2. Deactivating the account on the old PDS
#   3. Generating and adding rotation key for account recovery
#   4. Marking the migration as complete
#
# Status Flow:
#   pending_activation -> completed
#
# What This Job Does:
#   1. Activates account on new PDS (makes it live)
#   2. Deactivates account on old PDS (prevents further use)
#   3. Generates rotation key and adds it to PLC (highest priority)
#   4. Updates progress timestamps
#   5. Marks migration as complete
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
#   - rotation_key_public: public key (did:key format)
#   - rotation_key_generated_at: timestamp
#   - completed_at: timestamp (migration complete)
#
# Note: After this job completes, the user's account is fully migrated
# and operational on the new PDS. The old PDS account is deactivated
# but data remains there (could be deleted later if desired).

class ActivateAccountJob < ApplicationJob
  queue_as :critical
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

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

    # Step 2.5: Generate and add rotation key for account recovery
    # This happens AFTER activation and PLC update, so the new PDS has authority to sign the PLC operation
    begin
      Rails.logger.info("Generating rotation key for account recovery")
      rotation_key = service.generate_rotation_key
      migration.set_rotation_key(rotation_key[:private_key])
      Rails.logger.info("Rotation key generated and stored (public key: #{rotation_key[:public_key]})")

      Rails.logger.info("Adding rotation key to PDS account (highest priority)")
      service.add_rotation_key_to_pds(rotation_key[:public_key])
      Rails.logger.info("Rotation key added successfully")

      # Update progress
      migration.progress_data['rotation_key_public'] = rotation_key[:public_key]
      migration.progress_data['rotation_key_generated_at'] = Time.current.iso8601
      migration.save!
    rescue StandardError => e
      # Log the error but don't fail the migration
      # The account is already migrated successfully
      Rails.logger.warn("Failed to generate/add rotation key for migration #{migration.token}: #{e.message}")
      Rails.logger.warn("Migration will proceed as complete - user can add rotation key manually later")

      # Update progress with error note
      migration.progress_data['rotation_key_error'] = e.message
      migration.save!
    end

    # Step 3: Mark migration as complete
    Rails.logger.info("Marking migration complete for #{migration.token}")
    migration.progress_data['completed_at'] = Time.current.iso8601
    migration.save!

    migration.mark_complete!

    # Step 4: SECURITY - Clear encrypted credentials after successful migration
    # Passwords and tokens are no longer needed after migration completes
    Rails.logger.info("Clearing encrypted credentials for security")
    migration.clear_credentials!
    Rails.logger.info("Credentials successfully cleared for migration #{migration.token}")

    Rails.logger.info("=" * 80)
    Rails.logger.info("MIGRATION COMPLETE")
    Rails.logger.info("Token: #{migration.token}")
    Rails.logger.info("DID: #{migration.did}")
    Rails.logger.info("Old Handle: #{migration.old_handle} @ #{migration.old_pds_host}")
    Rails.logger.info("New Handle: #{migration.new_handle} @ #{migration.new_pds_host}")
    Rails.logger.info("Account is now live on new PDS")
    if migration.progress_data['rotation_key_public']
      Rails.logger.info("Rotation key added: #{migration.progress_data['rotation_key_public']}")
      Rails.logger.info("Rotation key private key available via: /migrations/#{migration.token}")
    elsif migration.progress_data['rotation_key_error']
      Rails.logger.warn("Rotation key generation failed (migration still successful)")
    end
    Rails.logger.info("Credentials cleared for security")
    Rails.logger.info("=" * 80)

  rescue GoatService::RateLimitError => e
    Rails.logger.warn("Rate limit hit for migration #{migration.token}: #{e.message}")
    Rails.logger.warn("Will retry with exponential backoff")
    migration.update(last_error: "Rate limit: #{e.message}")
    raise  # Re-raise to trigger ActiveJob retry with polynomially_longer backoff

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
    Rails.logger.error("Unexpected error for migration #{migration&.token || migration_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    migration&.mark_failed!("Account activation failed: #{e.message}")
    raise
  end
end
