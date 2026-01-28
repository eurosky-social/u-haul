# ImportPrefsJob - Migrates user preferences between PDS instances
#
# This job exports preferences (follows, blocks, mutes, content filters, etc.)
# from the old PDS and imports them to the new PDS.
#
# Status Flow:
#   pending_prefs -> pending_plc
#
# Retries: 3 times (preferences are idempotent)
# Queue: :migrations (medium priority)
#
# Error Handling:
#   - Retries on transient network failures
#   - Updates migration.last_error on failure
#   - Increments retry_count
#
# Progress Tracking:
#   Updates progress_data with:
#   - preferences_exported_at: timestamp
#   - preferences_imported_at: timestamp

class ImportPrefsJob < ApplicationJob
  queue_as :migrations
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  # Special handling for rate-limiting errors with longer backoff
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform(migration)
    Rails.logger.info("Starting preferences import for migration #{migration.token} (#{migration.did})")

    # Initialize GoatService
    service = GoatService.new(migration)

    # Step 1: Export preferences from old PDS
    Rails.logger.info("Exporting preferences from old PDS")
    prefs_path = service.export_preferences

    # Update progress
    migration.progress_data['preferences_exported_at'] = Time.current.iso8601
    migration.save!

    # Step 2: Import preferences to new PDS
    Rails.logger.info("Importing preferences to new PDS")
    service.import_preferences(prefs_path)

    # Update progress
    migration.progress_data['preferences_imported_at'] = Time.current.iso8601
    migration.save!

    # Step 3: Advance to pending_plc status
    Rails.logger.info("Preferences migration completed, advancing to pending_plc")
    migration.advance_to_pending_plc!

    Rails.logger.info("Preferences import completed successfully for migration #{migration.token}")

  rescue GoatService::RateLimitError => e
    Rails.logger.warn("Rate limit hit for migration #{migration.token}: #{e.message}")
    Rails.logger.warn("Will retry with exponential backoff")
    migration.update(last_error: "Rate limit: #{e.message}")
    raise  # Re-raise to trigger ActiveJob retry with polynomially_longer backoff

  rescue GoatService::AuthenticationError => e
    Rails.logger.error("Authentication failed for migration #{migration.token}: #{e.message}")
    migration.mark_failed!("Preferences import failed: Authentication error - #{e.message}")
    raise
  rescue GoatService::NetworkError => e
    Rails.logger.error("Network error for migration #{migration.token}: #{e.message}")
    migration.mark_failed!("Preferences import failed: Network error - #{e.message}")
    raise
  rescue GoatService::GoatError => e
    Rails.logger.error("Goat error for migration #{migration.token}: #{e.message}")
    migration.mark_failed!("Preferences import failed: #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.error("Unexpected error for migration #{migration.token}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    migration.mark_failed!("Preferences import failed: #{e.message}")
    raise
  end
end
