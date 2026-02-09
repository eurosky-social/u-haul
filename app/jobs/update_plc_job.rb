# UpdatePlcJob - CRITICAL - Point of No Return for Account Migration
#
# This job updates the PLC (Public Ledger of Credentials) directory to point
# the user's DID to the new PDS. This is the CRITICAL step that makes the
# migration irreversible.
#
# Status Flow:
#   pending_plc -> pending_activation
#
# What This Job Does:
#   1. Retrieves user-submitted PLC token from migration record (must not be expired)
#   2. Gets recommended PLC operation from new PDS
#   3. Signs the PLC operation with old PDS using the token
#   4. Submits the signed operation to PLC directory
#   5. Clears the encrypted PLC token for security
#   6. Advances to pending_activation
#
# Retries: 1 time only (this is critical and must succeed or fail definitively)
# Queue: :critical (highest priority)
#
# Error Handling:
#   - If the PLC token is expired or missing, fails immediately
#   - If PLC update fails, marks migration as failed with alert
#   - Logs extensively for debugging
#   - Only one retry to avoid repeated PLC operations
#
# Security:
#   - Clears encrypted_plc_token after successful submission
#   - Logs all PLC operations for audit trail
#
# WARNING: Once this job completes successfully, the DID points to the new PDS.
# The old PDS should be deactivated but the user account will now resolve to
# the new PDS for all ATProto operations.

class UpdatePlcJob < ApplicationJob
  queue_as :critical
  retry_on StandardError, wait: 30.seconds, attempts: 1

  # Special handling for rate-limiting errors - retry more times for this critical job
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 3

  def perform(migration_id)
    migration = Migration.find(migration_id)
    Rails.logger.info("CRITICAL: Starting PLC update for migration #{migration.token} (#{migration.did})")
    Rails.logger.info("This is the point of no return - the DID will be pointed to the new PDS")

    # Idempotency check: Skip if already past this stage
    # NOTE: We check for pending_plc OR pending_activation because this job is triggered
    # manually by the user submitting the PLC token, and the status might still be pending_plc
    unless ['pending_plc', 'pending_activation'].include?(migration.status)
      Rails.logger.info("Migration #{migration.token} is already at status '#{migration.status}', skipping PLC update")
      return
    end

    # Step 1: Validate PLC token is present and not expired
    plc_token = migration.plc_token
    if plc_token.nil?
      error_msg = "PLC token is missing or expired (credentials_expires_at: #{migration.credentials_expires_at})"
      Rails.logger.error(error_msg)
      migration.mark_failed!(error_msg)
      raise GoatService::AuthenticationError, error_msg
    end

    Rails.logger.info("PLC token retrieved and validated for migration #{migration.token}")

    # Initialize GoatService
    service = GoatService.new(migration)

    # Step 2: Get recommended PLC operation from new PDS
    Rails.logger.info("Getting recommended PLC operation parameters from new PDS")
    unsigned_op_path = service.get_recommended_plc_operation

    # Update progress
    migration.progress_data['plc_operation_recommended_at'] = Time.current.iso8601
    migration.save!

    # Step 3: Sign the PLC operation with old PDS
    Rails.logger.info("Signing PLC operation with old PDS using token")
    signed_op_path = service.sign_plc_operation(unsigned_op_path, plc_token)

    # Update progress
    migration.progress_data['plc_operation_signed_at'] = Time.current.iso8601
    migration.save!

    # Step 4: Submit the signed operation to PLC directory
    Rails.logger.info("CRITICAL: Submitting signed PLC operation to directory")
    service.submit_plc_operation(signed_op_path)

    # Update progress
    migration.progress_data['plc_operation_submitted_at'] = Time.current.iso8601
    migration.save!

    Rails.logger.info("SUCCESS: PLC operation submitted successfully for migration #{migration.token}")
    Rails.logger.info("DID #{migration.did} now points to new PDS: #{migration.new_pds_host}")

    # Step 5: Clear the PLC token for security
    Rails.logger.info("Clearing encrypted PLC token for security")
    migration.update!(encrypted_plc_token: nil)

    # Step 6: Advance to pending_activation
    Rails.logger.info("Advancing to pending_activation")
    migration.advance_to_pending_activation!

    Rails.logger.info("PLC update completed successfully for migration #{migration.token}")

  rescue GoatService::RateLimitError => e
    Rails.logger.warn("CRITICAL JOB: Rate limit hit for migration #{migration.token}: #{e.message}")
    Rails.logger.warn("Will retry with exponential backoff (up to 3 attempts for this critical job)")
    migration.update(last_error: "Rate limit: #{e.message}")
    raise  # Re-raise to trigger ActiveJob retry with polynomially_longer backoff

  rescue GoatService::AuthenticationError => e
    Rails.logger.error("CRITICAL FAILURE: Authentication failed for migration #{migration.token}: #{e.message}")
    Rails.logger.error("This is a critical failure - manual intervention required")
    migration.mark_failed!("CRITICAL: PLC update failed - Authentication error - #{e.message}")
    alert_admin_of_critical_failure(migration, e)
    raise
  rescue GoatService::NetworkError => e
    Rails.logger.error("CRITICAL FAILURE: Network error for migration #{migration.token}: #{e.message}")
    Rails.logger.error("This is a critical failure - manual intervention required")
    migration.mark_failed!("CRITICAL: PLC update failed - Network error - #{e.message}")
    alert_admin_of_critical_failure(migration, e)
    raise
  rescue GoatService::GoatError => e
    Rails.logger.error("CRITICAL FAILURE: Goat error for migration #{migration.token}: #{e.message}")
    Rails.logger.error("This is a critical failure - manual intervention required")
    migration.mark_failed!("CRITICAL: PLC update failed - #{e.message}")
    alert_admin_of_critical_failure(migration, e)
    raise
  rescue StandardError => e
    Rails.logger.error("CRITICAL FAILURE: Unexpected error for migration #{migration&.token || migration_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    Rails.logger.error("This is a critical failure - manual intervention required")
    if migration
      migration.mark_failed!("CRITICAL: PLC update failed - #{e.message}")
      alert_admin_of_critical_failure(migration, e)
    end
    raise
  end

  private

  def alert_admin_of_critical_failure(migration, error)
    # Log prominently for admin monitoring
    Rails.logger.error("=" * 80)
    Rails.logger.error("CRITICAL MIGRATION FAILURE - ADMIN ALERT")
    Rails.logger.error("Migration Token: #{migration.token}")
    Rails.logger.error("DID: #{migration.did}")
    Rails.logger.error("Email: #{migration.email}")
    Rails.logger.error("Error: #{error.class.name} - #{error.message}")
    Rails.logger.error("Status: PLC update failed - requires manual recovery")
    Rails.logger.error("=" * 80)

    # Send critical failure email to user
    begin
      MigrationMailer.critical_plc_failure(migration).deliver_later
      Rails.logger.info("Sent critical failure notification to #{migration.email}")
    rescue => email_error
      Rails.logger.error("Failed to send critical failure email: #{email_error.message}")
    end

    # TODO: Add additional alerting mechanisms
    # AdminMailer.critical_migration_failure(migration, error).deliver_later
    # SlackNotifier.alert_critical_failure(migration, error)
    # PagerDuty.trigger_incident(migration, error)
  end
end
