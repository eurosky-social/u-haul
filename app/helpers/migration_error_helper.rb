# MigrationErrorHelper - User-friendly error messages and recovery guidance
#
# Transforms technical error messages into actionable, user-friendly explanations
# with context, next steps, and recovery options.
#
# Usage:
#   error_context = MigrationErrorHelper.explain_error(migration)
#   => {
#        severity: :warning | :error | :critical,
#        title: "Network Error During Blob Transfer",
#        what_happened: "Connection to old PDS timed out...",
#        current_status: "Automatically retrying (attempt 2/3)",
#        what_to_do: ["Wait for automatic retry", "Check old PDS status"],
#        show_retry_button: true,
#        technical_details: "GoatService::NetworkError: ..."
#      }

module MigrationErrorHelper
  # Main entry point - explains the current error state
  def self.explain_error(migration)
    return nil unless migration.last_error.present?

    error_message = migration.last_error
    job_step = migration.current_job_step
    retry_attempt = migration.current_job_attempt || 0
    max_attempts = migration.current_job_max_attempts || 3

    # Prefer structured error_code; fall back to regex detection for old records
    error_type = if migration.respond_to?(:error_code) && migration.error_code.present?
      migration.error_code.to_sym
    else
      detect_error_type(error_message)
    end

    # Build context based on error type and migration stage
    context = build_error_context(
      error_type: error_type,
      error_message: error_message,
      migration: migration,
      job_step: job_step,
      retry_attempt: retry_attempt,
      max_attempts: max_attempts
    )

    context
  end

  # Detect error type from error message
  #
  # Each pattern is anchored (\A) or uses phrases unique to one mark_failed! call
  # site so that error types never cross-match. See the comments for the exact
  # messages each pattern targets.
  def self.detect_error_type(error_message)
    case error_message
    when /rate limit|429|RateLimitExceeded/i
      :rate_limit

    # --- PLC-related errors (most specific first) ---

    # PLC OTP token expired or missing (UpdatePlcJob early-return checks)
    #   "PLC token has expired (expired at: ...). Please request a new token."
    #   "PLC token is missing. Please request a new token."
    #   "PLC confirmation code expired. The code from your old PDS..."
    when /\APLC token has expired/, /\APLC token is missing/, /\APLC confirmation code expired/
      :plc_token_expired

    # Post-submission critical PLC failure (UpdatePlcJob rescue, plc_submitted=true)
    #   "CRITICAL: PLC update failed after submission - ..."
    when /\ACRITICAL: PLC update failed after submission/
      :critical_plc

    # Pre-submission recoverable PLC failure (UpdatePlcJob rescue, plc_submitted=false)
    #   "PLC update failed (before submission) - ..."
    when /\APLC update failed \(before submission\)/
      :plc_pre_submission_failure

    # --- Credential / auth errors ---

    # Credentials expired — need re-authentication (UpdatePlcJob credential check)
    #   "Credentials expired: ... no longer available. Please re-authenticate to continue."
    when /\ACredentials expired:.*re-authenticate/
      :credentials_need_reauth

    # Authentication failure (wrong password, 401, etc.)
    when /authentication|unauthorized|401|invalid password/i
      :authentication

    # --- Infrastructure / data errors ---

    when /network|timeout|connection|unreachable/i
      :network
    when /already exists|AlreadyExists|orphaned/i
      :account_exists
    when /invite.*code/i
      :invite_code
    when /blob.*not found|404/i
      :blob_not_found
    when /corrupt|invalid.*format|parse error/i
      :data_corruption
    when /disk.*full|out of space|no space/i
      :disk_space
    when /cancelled by user/i
      :cancelled

    # Legacy catch-all for older "CRITICAL:" PLC messages (before pre/post split)
    when /\ACRITICAL:.*PLC/
      :critical_plc

    else
      :generic
    end
  end

  # Build user-friendly error context
  def self.build_error_context(error_type:, error_message:, migration:, job_step:, retry_attempt:, max_attempts:)
    base_context = case error_type
    when :rate_limit
      rate_limit_context(migration, retry_attempt, max_attempts)
    when :network
      network_context(migration, retry_attempt, max_attempts)
    when :plc_token_expired
      plc_token_expired_context(migration)
    when :plc_pre_submission_failure
      plc_pre_submission_failure_context(migration)
    when :credentials_need_reauth
      credentials_need_reauth_context(migration)
    when :authentication
      authentication_context(migration)
    when :account_exists
      account_exists_context(migration)
    when :blob_not_found
      blob_not_found_context(migration)
    when :data_corruption
      data_corruption_context(migration, retry_attempt, max_attempts)
    when :disk_space
      disk_space_context(migration)
    when :invite_code
      invite_code_context(migration)
    when :email_taken
      email_taken_context(migration)
    when :cancelled
      cancelled_context(migration)
    when :critical_plc
      critical_plc_context(migration)
    else
      generic_context(migration, retry_attempt, max_attempts)
    end

    # Add technical details
    base_context[:technical_details] = error_message
    base_context[:job_step] = job_step

    # Only include retry info when the error type supports automatic retries
    unless base_context[:show_retry_info] == false
      base_context[:retry_info] = {
        attempt: retry_attempt,
        max_attempts: max_attempts,
        remaining: [max_attempts - retry_attempt, 0].max
      }
    end

    base_context
  end

  # Error context builders for each type

  def self.rate_limit_context(migration, retry_attempt, max_attempts)
    {
      severity: :warning,
      icon: "⚠️",
      title: "Rate Limited by Server",
      what_happened: "The server is rate-limiting requests to prevent overload. This is normal behavior when many migrations are running.",
      current_status: retry_attempt < max_attempts ? "Automatically retrying with longer delays (attempt #{retry_attempt}/#{max_attempts})" : "All retries exhausted",
      what_to_do: [
        "Wait for automatic retry (recommended) - each retry uses a longer delay",
        "Rate limiting is temporary and usually resolves within a few minutes",
        "If this persists after #{max_attempts} retries, the server may be overloaded"
      ],
      show_retry_button: retry_attempt >= max_attempts,
      help_link: "/docs/troubleshooting#rate-limiting"
    }
  end

  def self.network_context(migration, retry_attempt, max_attempts)
    stage_info = case migration.status
    when 'pending_repo'
      { target: "old PDS", url: migration.old_pds_host, operation: "repository export" }
    when 'pending_blobs'
      { target: "old PDS", url: migration.old_pds_host, operation: "blob download" }
    when 'pending_activation'
      { target: "new PDS", url: migration.new_pds_host, operation: "account activation" }
    else
      { target: "PDS", url: migration.old_pds_host, operation: "migration operation" }
    end

    {
      severity: :warning,
      icon: "🌐",
      title: "Network Connection Error",
      what_happened: "Connection to #{stage_info[:target]} timed out or was interrupted during #{stage_info[:operation]}.",
      current_status: retry_attempt < max_attempts ? "Automatically retrying (attempt #{retry_attempt}/#{max_attempts})" : "All retries exhausted",
      what_to_do: [
        "Wait for automatic retry (recommended)",
        "Check if #{stage_info[:url]} is accessible from your browser",
        "If errors persist, the PDS may be temporarily down or experiencing high load",
        "Contact the PDS administrator if the problem continues"
      ],
      show_retry_button: retry_attempt >= max_attempts,
      help_link: "/docs/troubleshooting#network-errors",
      check_url: stage_info[:url]
    }
  end

  def self.authentication_context(migration)
    {
      severity: :error,
      icon: "🔐",
      title: "Authentication Failed",
      what_happened: "Could not authenticate with your PDS. This usually means the password is incorrect or has expired.",
      current_status: "Migration stopped - requires new credentials",
      what_to_do: [
        "Verify your password is correct",
        "Check if your credentials have expired (48 hour limit from migration start)",
        "Start a new migration with correct credentials",
        "If you're sure the password is correct, contact your PDS administrator"
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_new_migration_button: true,
      help_link: "/docs/troubleshooting#authentication-errors",
      credentials_expire_at: migration.credentials_expires_at
    }
  end

  def self.email_taken_context(migration)
    contact_email = migration.target_pds_contact_email.presence || ENV.fetch('SUPPORT_EMAIL', 'support@example.com')

    {
      severity: :error,
      icon: "📧",
      title: "Email Address Already Registered on Target PDS",
      what_happened: "#{migration.new_pds_host} already has an account registered with #{migration.email}, " \
                     "so a new account for your DID could not be created there. " \
                     "Your account on #{migration.old_pds_host} is untouched.",
      current_status: "Migration stopped — no changes were made to your identity",
      what_to_do: [
        "If that account is yours, log in to it on #{migration.new_pds_host}, change its email address, then start a new migration",
        "Or start a new migration using a different email address",
        "If you don't recognise the account, contact the PDS provider: #{contact_email}"
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_contact_support: true,
      support_email: contact_email,
      migration_token: migration.token,
      did: migration.did
    }
  end

  # The new-account password (migration_out) was rejected by the target PDS,
  # typically because the user reset it there while the migration was pending
  # (which also revokes the sessions we stored).
  def self.new_pds_login_failed?(migration)
    migration.migration_out? &&
      migration.last_error.to_s.match?(/login to new PDS|new PDS password|Invalid identifier or password/i)
  end

  def self.account_exists_context(migration)
    contact_email = migration.target_pds_contact_email.presence || ENV.fetch('SUPPORT_EMAIL', 'support@example.com')

    {
      severity: :error,
      icon: "👥",
      title: "Account Already Exists on Target PDS",
      what_happened: "An account with your DID already exists on the target PDS (#{migration.new_pds_host}). This orphaned account is likely from a previous failed migration attempt.",
      current_status: "Migration paused - orphaned account needs removal by PDS provider",
      what_to_do: [
        "📧 Contact the target PDS provider to remove the orphaned account:",
        "   Email: #{contact_email}",
        "   Include: Migration Token (#{migration.token}) and DID (#{migration.did})",
        "",
        "Once the orphaned account is removed, you can retry this migration.",
        "",
        "⚠️ This requires action from the PDS provider - you cannot fix this yourself."
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_contact_support: true,
      support_email: contact_email,
      migration_token: migration.token,
      help_link: "/docs/troubleshooting#orphaned-accounts",
      did: migration.did
    }
  end

  def self.plc_token_expired_context(migration)
    {
      severity: :warning,
      icon: "⏰",
      title: "PLC Token Expired",
      what_happened: "The PLC operation token you submitted has expired. PLC tokens are only valid for 1 hour after they are issued by your old PDS provider.",
      current_status: "Migration paused - new PLC token required",
      what_to_do: [
        "Click the 'Request New PLC Token' button below to request a fresh token",
        "Check your email from #{migration.old_pds_host} for the new token",
        "Submit the new token within 1 hour of receiving it",
        "The rest of your migration data is safe and ready - you just need a fresh token"
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_request_new_plc_token: true,
      help_link: "/docs/troubleshooting#plc-token-expiration",
      expired_at: migration.credentials_expires_at,
      old_pds_host: migration.old_pds_host
    }
  end

  def self.plc_pre_submission_failure_context(migration)
    {
      severity: :warning,
      icon: "⚠️",
      title: "PLC Update Could Not Complete",
      what_happened: "The PLC directory update could not be completed, but your account is safe. " \
                     "The PLC directory was NOT modified — your account remains on #{migration.old_pds_host}.",
      current_status: "Migration paused — request a new confirmation code to try again",
      what_to_do: [
        "Click 'Request New PLC Token' below to get a fresh confirmation code",
        "Check your email from #{migration.old_pds_host} for the new code",
        "Submit the new code within 1 hour of receiving it",
        "Your migration data (repository, blobs, preferences) is safe and ready"
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_request_new_plc_token: true,
      show_new_pds_reauth_form: new_pds_login_failed?(migration),
      help_link: "/docs/troubleshooting#plc-token-expiration",
      old_pds_host: migration.old_pds_host
    }
  end

  def self.credentials_need_reauth_context(migration)
    {
      severity: :warning,
      icon: "🔑",
      title: "Session Expired — Re-authentication Required",
      what_happened: "Your stored credentials have expired. For security, credentials are automatically cleared after 48 hours. " \
                     "To continue the migration, you need to re-authenticate.",
      current_status: "Migration paused — re-authentication required to continue",
      what_to_do: [
        "Enter your password below to re-authenticate",
        "Your migration data is safe — you just need fresh credentials",
        "After re-authenticating, the migration will continue where it left off"
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_reauth_form: true,
      show_new_pds_reauth_form: new_pds_login_failed?(migration),
      help_link: "/docs/troubleshooting#credential-expiration",
      old_pds_host: migration.old_pds_host
    }
  end

  def self.blob_not_found_context(migration)
    {
      severity: :warning,
      icon: "🖼️",
      title: "Some Blobs Not Found",
      what_happened: "Some blobs (images/videos) were not found on the old PDS. They may have been deleted or are no longer available.",
      current_status: "Migration continuing - missing blobs will be skipped",
      what_to_do: [
        "This is usually not critical - migration will continue without these blobs",
        "Missing blobs may mean some old images/videos won't transfer",
        "Check the failed blobs manifest for details after migration completes",
        "You can manually re-upload missing media after migration if needed"
      ],
      show_retry_button: false,
      show_download_manifest: true,
      help_link: "/docs/troubleshooting#missing-blobs"
    }
  end

  def self.data_corruption_context(migration, retry_attempt, max_attempts)
    {
      severity: :warning,
      icon: "💾",
      title: "Data Transfer Corruption",
      what_happened: "Data was corrupted during transfer. This can happen on slow or unstable network connections.",
      current_status: retry_attempt < max_attempts ? "Re-downloading corrupted data (attempt #{retry_attempt}/#{max_attempts})" : "All retries exhausted",
      what_to_do: [
        "Wait for automatic retry - the data will be re-downloaded",
        "If this persists, check your network connection quality",
        "Try using a more stable network connection",
        "Large repositories may timeout on slow connections"
      ],
      show_retry_button: retry_attempt >= max_attempts,
      help_link: "/docs/troubleshooting#data-corruption"
    }
  end

  def self.disk_space_context(migration)
    {
      severity: :error,
      icon: "💿",
      title: "Disk Space Exhausted",
      what_happened: "The server or PDS has run out of disk space.",
      current_status: "Migration stopped - requires administrator intervention",
      what_to_do: [
        "Contact the server/PDS administrator to free up disk space",
        "This is a server-side issue that cannot be resolved by retrying",
        "Once disk space is freed, you can retry the migration"
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_contact_admin: true,
      help_link: "/docs/troubleshooting#disk-space"
    }
  end

  def self.invite_code_context(migration)
    {
      severity: :error,
      icon: "🎫",
      title: "Invalid or Expired Invite Code",
      what_happened: "The invite code provided is invalid, expired, or has already been used.",
      current_status: "Migration stopped - requires valid invite code",
      what_to_do: [
        "Obtain a new invite code from the target PDS administrator",
        "Verify the invite code is copied correctly (no extra spaces)",
        "Start a new migration with the correct invite code",
        "Some PDS instances don't require invite codes - check with the administrator"
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_new_migration_button: true,
      help_link: "/docs/troubleshooting#invite-codes"
    }
  end

  def self.cancelled_context(migration)
    {
      severity: :warning,
      icon: "🚫",
      title: "Migration Cancelled",
      what_happened: "This migration was cancelled at your request. No changes were made to your account.",
      current_status: "Migration cancelled — your account remains on #{migration.old_pds_host}",
      what_to_do: [
        "Your account is safe and unchanged on #{migration.old_pds_host}",
        "You can start a new migration at any time"
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_new_migration_button: true
    }
  end

  def self.critical_plc_context(migration)
    # Check if PLC operation was actually submitted to the directory.
    # The rotation key is generated BEFORE submission as a safety net,
    # so its presence does NOT mean the PLC was updated.
    plc_not_yet_updated = migration.progress_data&.dig('plc_operation_submitted_at').blank?
    support_email = ENV.fetch('SUPPORT_EMAIL', 'support@example.com')

    base_context = {
      severity: :critical,
      icon: "⚠️",
      title: "PLC Directory Update Failed",
      what_happened: "The PLC directory update did not complete successfully. Your account data is safe.",
      current_status: plc_not_yet_updated ? "The PLC directory was not modified — you can request a new token and try again." : "The PLC directory may have been partially updated. Please contact support.",
      what_to_do: [
        "Do not start a new migration",
        "Your account data is safe and intact",
        migration.rotation_key.present? ? "Your recovery key is available on this page — save it securely" : nil,
        "Save this migration token: #{migration.token}",
        "Contact support if the issue persists: #{support_email}"
      ].compact,
      show_retry_button: false,
      show_retry_info: false,
      show_contact_support: true,
      show_rotation_key: true,
      show_request_new_plc_token: true,  # Always show for PLC failures - user may need new token
      help_link: "/docs/troubleshooting#critical-plc-failure",
      migration_token: migration.token,
      support_email: support_email
    }

    # If PLC was not yet updated, emphasize token request
    if plc_not_yet_updated
      base_context[:what_to_do].unshift("Try requesting a new PLC token - the update hasn't happened yet")
    end

    base_context
  end

  def self.generic_context(migration, retry_attempt, max_attempts)
    {
      severity: :warning,
      icon: "⚠️",
      title: "Migration Error",
      what_happened: "An error occurred during the migration process.",
      current_status: retry_attempt < max_attempts ? "Automatically retrying (attempt #{retry_attempt}/#{max_attempts})" : "All retries exhausted",
      what_to_do: [
        "Wait for automatic retry",
        "If this persists, check the technical details below",
        "Contact support if you need assistance: #{ENV.fetch('SUPPORT_EMAIL', 'support@example.com')}"
      ],
      show_retry_button: retry_attempt >= max_attempts,
      help_link: "/docs/troubleshooting"
    }
  end

  # Helper methods

  def self.time_until_retry(migration)
    # Calculate next retry time based on exponential backoff
    # This would need to integrate with Sidekiq's retry schedule
    # For now, return estimated times
    attempt = migration.current_job_attempt || 0
    base_delay = 2 # seconds

    case attempt
    when 0, 1
      base_delay * (2 ** attempt)
    when 2
      base_delay * (2 ** attempt)
    else
      30 # polynomial backoff approximation
    end
  end

  def self.format_time_remaining(seconds)
    return "a few moments" if seconds < 5

    if seconds < 60
      "#{seconds} seconds"
    elsif seconds < 3600
      minutes = (seconds / 60).round
      "#{minutes} minute#{'s' if minutes != 1}"
    else
      hours = (seconds / 3600).round
      "#{hours} hour#{'s' if hours != 1}"
    end
  end
end
