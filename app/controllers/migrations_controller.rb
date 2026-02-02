# MigrationsController - User-facing controller for PDS migrations
#
# This controller provides both HTML views for users and JSON API endpoints
# for status polling. No authentication is required - access is controlled
# via the migration token in the URL.
#
# Actions:
#   - new: Display migration form
#   - create: Start a new migration, generate token, redirect to status page
#   - show: Display status page (HTML) or return JSON based on format
#   - submit_plc_token: Accept and store the PLC token, trigger UpdatePlcJob
#   - status: JSON API endpoint for real-time status polling
#
# Security:
#   - Token-based access only (no user authentication)
#   - Tokens are found via URL parameter, not database ID
#   - PLC tokens are encrypted before storage
#   - Credentials have expiration times
#
# Routes:
#   GET  /migrations/new
#   POST /migrations
#   GET  /migrations/:id
#   GET  /migrate/:token (alias for show)
#   POST /migrations/:id/submit_plc_token
#   POST /migrate/:token/plc_token (alias for submit_plc_token)
#   GET  /migrations/:id/status (JSON only)

class MigrationsController < ApplicationController
  before_action :set_migration, only: [:show, :submit_plc_token, :status, :download_backup, :retry, :cancel]

  # GET /migrations/new
  # Display the migration form where users enter their account details
  def new
    @migration = Migration.new

    # Pre-populate new_pds_host in bound mode
    if EuroskyConfig.bound_mode?
      @migration.new_pds_host = EuroskyConfig::TARGET_PDS_HOST
    end
  end

  # POST /migrations
  # Create a new migration and redirect to the status page
  #
  # Params:
  #   - migration[email]: User's email address
  #   - migration[old_handle]: Current handle (e.g., user.bsky.social)
  #   - migration[new_handle]: New handle (e.g., user.example.com)
  #   - migration[new_pds_host]: New PDS host (e.g., pds.example.com)
  #   - password: Account password (stored encrypted, not mass-assigned)
  #
  # Note: old_pds_host and did are resolved automatically from old_handle
  #
  # Response:
  #   - Success: Redirects to status page with token
  #   - Failure: Re-renders form with errors
  def create
    @migration = Migration.new(migration_params)

    begin
      # Sanitize handles by removing invisible Unicode characters and trimming whitespace
      @migration.old_handle = sanitize_handle(@migration.old_handle) if @migration.old_handle.present?
      @migration.new_handle = sanitize_handle(@migration.new_handle) if @migration.new_handle.present?

      # Resolve the old handle to get DID and PDS host
      if @migration.old_handle.present?
        resolution = GoatService.resolve_handle(@migration.old_handle)
        @migration.did = resolution[:did]
        @migration.old_pds_host = resolution[:pds_host]

        Rails.logger.info("Resolved handle #{@migration.old_handle}: DID=#{@migration.did}, PDS=#{@migration.old_pds_host}")
      end

      # Auto-detect migration type: if new_pds_host is bsky.social and old_pds_host is not, this is migration_in
      if @migration.new_pds_host.present? && @migration.old_pds_host.present?
        new_host_normalized = @migration.new_pds_host.downcase.gsub(%r{https?://}, '')
        old_host_normalized = @migration.old_pds_host.downcase.gsub(%r{https?://}, '')

        if new_host_normalized.include?('bsky.social') && !old_host_normalized.include?('bsky.social')
          @migration.migration_type = 'migration_in'
          Rails.logger.info("Auto-detected migration_in (returning to Bluesky)")

          # CRITICAL: Verify the account actually exists on bsky.social before starting migration
          Rails.logger.info("Verifying pre-existing account on bsky.social for DID: #{@migration.did}")
          begin
            account_check = verify_account_exists_on_pds(@migration.new_pds_host, @migration.did)

            unless account_check[:exists]
              @migration.errors.add(:base, "Cannot migrate back to bsky.social: No account found with your DID (#{@migration.did}). " \
                "Migration_in (returning to Bluesky) is only for users who previously had a bsky.social account. " \
                "If you've never had a bsky.social account, you cannot migrate to it - bsky.social does not accept new accounts via migration.")
              render :new, status: :unprocessable_entity
              return
            end

            Rails.logger.info("Pre-existing account verified on bsky.social (deactivated: #{account_check[:deactivated]}, handle: #{account_check[:handle]})")
          rescue StandardError => e
            Rails.logger.error("Failed to verify pre-existing account on bsky.social: #{e.message}")
            @migration.errors.add(:base, "Failed to verify account existence on bsky.social: #{e.message}. " \
              "Please ensure you have a pre-existing bsky.social account before attempting to migrate back.")
            render :new, status: :unprocessable_entity
            return
          end
        else
          @migration.migration_type = 'migration_out'
          Rails.logger.info("Auto-detected migration_out (migrating to new PDS)")
        end
      end

      # Set the password and expiration (Lockbox encrypts automatically)
      if params[:migration][:password].present?
        @migration.password = params[:migration][:password]
        @migration.credentials_expires_at = 48.hours.from_now
      end

      # Set the invite code if provided and enabled (Lockbox encrypts automatically)
      if EuroskyConfig.invite_code_enabled? && params[:migration][:invite_code].present?
        @migration.invite_code = params[:migration][:invite_code]
        @migration.invite_code_expires_at = 48.hours.from_now
      end

      if @migration.save
        # Migration saved successfully, token generated, CreateAccountJob scheduled
        redirect_to migration_by_token_path(@migration.token),
                    notice: "Migration started! Track your progress with token: #{@migration.token}"
      else
        render :new, status: :unprocessable_entity
      end
    rescue GoatService::NetworkError => e
      Rails.logger.error("Failed to resolve handle #{@migration.old_handle}: #{e.message}")
      @migration.errors.add(:old_handle, "could not be resolved. Please check that the handle is correct and try again.")
      render :new, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Unexpected error during migration creation: #{e.message}")
      @migration.errors.add(:base, "An unexpected error occurred. Please try again.")
      render :new, status: :unprocessable_entity
    end
  end

  # GET /migrations/:id
  # GET /migrate/:token
  # Display migration status page (HTML) or return JSON based on format
  #
  # Supports both ID-based and token-based access via different routes.
  # The token-based route is preferred for user-facing URLs.
  #
  # Formats:
  #   - HTML: Renders status page with progress bar
  #   - JSON: Returns migration status data (same as status action)
  def show
    if request.format.json?
      render json: migration_status_json
    else
      render :show
    end
  end

  # POST /migrations/:id/submit_plc_token
  # POST /migrate/:token/plc_token
  # Accept and store the PLC token from the user, then trigger UpdatePlcJob
  #
  # This endpoint is called when the user has obtained their PLC operation token
  # from their old PDS and submits it to complete the migration. This is the
  # critical "point of no return" step that will redirect their DID to the new PDS.
  #
  # Params:
  #   - plc_token: The PLC operation token from the old PDS
  #
  # Response:
  #   - Success: Redirects to status page with success message
  #   - Failure: Redirects to status page with error message
  def submit_plc_token
    plc_token = params[:plc_token]

    if plc_token.blank?
      redirect_to migration_by_token_path(@migration.token),
                  alert: "PLC token cannot be blank"
      return
    end

    # Store the encrypted PLC token with expiration
    @migration.set_plc_token(plc_token)

    # Trigger the critical UpdatePlcJob to update the PLC directory
    UpdatePlcJob.perform_later(@migration.id)

    redirect_to migration_by_token_path(@migration.token),
                notice: "PLC token submitted! Your DID will be updated shortly."
  rescue StandardError => e
    Rails.logger.error("Failed to submit PLC token for migration #{@migration.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: "Failed to submit PLC token: #{e.message}"
  end

  # GET /migrations/:id/status
  # JSON API endpoint for real-time status polling
  #
  # This endpoint is designed for AJAX polling from the status page.
  # It returns the current migration status, progress percentage,
  # estimated time remaining, and any errors.
  #
  # Response format:
  #   {
  #     "token": "EURO-ABC12345",
  #     "status": "pending_blobs",
  #     "progress_percentage": 45,
  #     "estimated_time_remaining": 300,
  #     "blob_count": 100,
  #     "blobs_uploaded": 45,
  #     "total_bytes_transferred": 1234567,
  #     "last_error": null,
  #     "created_at": "2026-01-27T10:00:00Z",
  #     "updated_at": "2026-01-27T10:15:00Z"
  #   }
  def status
    render json: migration_status_json
  end

  # GET /migrations/:id/download_backup
  # GET /migrate/:token/download
  # Download the backup bundle for this migration
  #
  # Security:
  #   - Token-based access only (no authentication required)
  #   - Backup must exist and not be expired
  #   - File is served with appropriate headers for download
  #
  # Response:
  #   - Success: Sends ZIP file with appropriate headers
  #   - Not Found: Returns 404 if backup doesn't exist or is expired
  def download_backup
    unless @migration.backup_available?
      render plain: "Backup not found or has expired", status: :not_found
      return
    end

    # Send the file with appropriate headers
    send_file(
      @migration.backup_bundle_path,
      filename: "eurosky-backup-#{@migration.token}.zip",
      type: 'application/zip',
      disposition: 'attachment'
    )

    Rails.logger.info("Backup downloaded for migration #{@migration.token}")
  rescue StandardError => e
    Rails.logger.error("Failed to download backup for migration #{@migration.token}: #{e.message}")
    render plain: "Failed to download backup: #{e.message}", status: :internal_server_error
  end

  # POST /migrate/:token/retry
  # Retry a failed migration from the current step
  #
  # Requirements:
  #   - Migration must be in failed status
  #   - Uses existing migration token
  #
  # Response:
  #   - Success: Redirects to status page with notice
  #   - Failure: Redirects to status page with alert
  def retry
    unless @migration.failed?
      redirect_to migration_by_token_path(@migration.token),
                  alert: "Migration is not in failed status and cannot be retried"
      return
    end

    # Reset error state and retry from the current status
    @migration.update!(
      status: determine_retry_status(@migration.status),
      last_error: nil,
      current_job_attempt: 0
    )

    # Enqueue the appropriate job based on the status
    enqueue_job_for_status(@migration)

    Rails.logger.info("Migration #{@migration.token} retry requested by user")
    redirect_to migration_by_token_path(@migration.token),
                notice: "Migration retry started!"
  rescue StandardError => e
    Rails.logger.error("Failed to retry migration #{@migration.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: "Failed to retry migration: #{e.message}"
  end

  # POST /migrate/:token/cancel
  # Cancel a migration in progress
  #
  # Requirements:
  #   - Migration must not be in PLC or activation stage
  #   - Migration must not be already completed or failed
  #
  # Response:
  #   - Success: Redirects to status page with notice
  #   - Failure: Redirects to status page with alert
  def cancel
    unless @migration.can_cancel?
      redirect_to migration_by_token_path(@migration.token),
                  alert: "Migration cannot be cancelled at this stage"
      return
    end

    @migration.cancel!

    Rails.logger.info("Migration #{@migration.token} cancelled by user")
    redirect_to migration_by_token_path(@migration.token),
                notice: "Migration cancelled successfully"
  rescue StandardError => e
    Rails.logger.error("Failed to cancel migration #{@migration.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: "Failed to cancel migration: #{e.message}"
  end

  private

  # Find migration by token (from URL parameter)
  # Handles both :id and :token parameters to support different routes
  #
  # Routes:
  #   - /migrations/:id/status uses params[:id]
  #   - /migrate/:token uses params[:token]
  def set_migration
    token = params[:token] || params[:id]
    @migration = Migration.find_by(token: token)

    unless @migration
      if request.format.json?
        render json: { error: "Migration not found" }, status: :not_found
      else
        render plain: "Migration not found with token: #{token}", status: :not_found
      end
      return  # Halt the filter chain after rendering
    end
  end

  # Strong parameters for migration creation
  # The password, invite_code, old_pds_host, and did are handled separately and not mass-assigned
  # old_pds_host and did are automatically resolved from the old_handle
  def migration_params
    allowed = [:email, :old_handle, :new_handle, :create_backup_bundle]

    # Add new_pds_host only in standalone mode
    allowed << :new_pds_host if EuroskyConfig.standalone_mode?

    # Note: invite_code and password are handled separately for encryption
    # They are not mass-assigned through permit

    params.require(:migration).permit(*allowed)
  end

  # Format migration data for JSON API response
  # Includes all relevant status information for client-side polling
  def migration_status_json
    blob_data = calculate_blob_statistics

    {
      token: @migration.token,
      status: @migration.status,
      progress_percentage: @migration.progress_percentage,
      estimated_time_remaining: @migration.estimated_time_remaining,
      blob_count: blob_data[:count],
      blobs_uploaded: blob_data[:uploaded],
      total_bytes_transferred: blob_data[:bytes_transferred],
      last_error: @migration.last_error,
      created_at: @migration.created_at.iso8601,
      updated_at: @migration.updated_at.iso8601
    }
  end

  # Calculate blob upload statistics from progress_data
  # Returns a hash with count, uploaded, and bytes_transferred
  def calculate_blob_statistics
    blobs = @migration.progress_data['blobs'] || {}

    {
      count: blobs.size,
      uploaded: blobs.values.count { |b| b['uploaded'] == b['size'] },
      bytes_transferred: blobs.values.sum { |b| b['uploaded'].to_i }
    }
  end

  # Sanitize handle by removing invisible Unicode characters and trimming whitespace
  # This prevents issues with copy-pasted handles that may contain RTL marks, zero-width spaces, etc.
  def sanitize_handle(handle)
    return nil if handle.nil?

    # Remove common invisible Unicode characters:
    # - U+200B: Zero-width space
    # - U+200C: Zero-width non-joiner
    # - U+200D: Zero-width joiner
    # - U+200E: Left-to-right mark
    # - U+200F: Right-to-left mark
    # - U+202A-U+202E: Various directional formatting characters
    # - U+FEFF: Zero-width no-break space (BOM)
    handle.gsub(/[\u200B-\u200F\u202A-\u202E\uFEFF]/, '').strip
  end

  # Determine which status to retry from based on current failed status
  # Returns the status to set when retrying
  def determine_retry_status(current_status)
    # If migration failed during a specific step, retry from that step
    # Otherwise, start from the beginning
    case current_status
    when 'failed'
      # Check progress_data to see where we failed
      if @migration.current_job_step.present?
        status_from_job_step(@migration.current_job_step)
      else
        # Default to account creation if we don't know where we failed
        'pending_account'
      end
    else
      # Already have a valid status, keep it
      current_status
    end
  end

  # Convert job step name to status
  def status_from_job_step(job_step)
    case job_step
    when /DownloadAllDataJob/i then 'pending_download'
    when /CreateBackupBundleJob/i then 'pending_backup'
    when /CreateAccountJob/i then 'pending_account'
    when /UploadRepoJob|ImportRepoJob/i then 'pending_repo'
    when /UploadBlobsJob|ImportBlobsJob/i then 'pending_blobs'
    when /ImportPrefsJob/i then 'pending_prefs'
    when /WaitForPlcTokenJob|UpdatePlcJob/i then 'pending_plc'
    when /ActivateAccountJob/i then 'pending_activation'
    else 'pending_account' # Default fallback
    end
  end

  # Enqueue the appropriate job for the migration status
  def enqueue_job_for_status(migration)
    case migration.status
    when 'pending_download'
      DownloadAllDataJob.perform_later(migration.id)
    when 'pending_backup'
      CreateBackupBundleJob.perform_later(migration.id)
    when 'backup_ready', 'pending_account'
      CreateAccountJob.perform_later(migration.id)
    when 'pending_repo'
      if migration.create_backup_bundle && migration.downloaded_data_path.present?
        UploadRepoJob.perform_later(migration.id)
      else
        ImportRepoJob.perform_later(migration.id)
      end
    when 'pending_blobs'
      if migration.create_backup_bundle && migration.downloaded_data_path.present?
        UploadBlobsJob.perform_later(migration.id)
      else
        ImportBlobsJob.perform_later(migration.id)
      end
    when 'pending_prefs'
      ImportPrefsJob.perform_later(migration.id)
    when 'pending_plc'
      WaitForPlcTokenJob.perform_later(migration.id)
    when 'pending_activation'
      ActivateAccountJob.perform_later(migration.id)
    else
      raise "Cannot enqueue job for status: #{migration.status}"
    end
  end

  # Verify that an account exists on a PDS (for migration_in validation)
  # Returns { exists: boolean, deactivated: boolean, handle: string }
  def verify_account_exists_on_pds(pds_host, did)
    url = "#{pds_host}/xrpc/com.atproto.repo.describeRepo?repo=#{did}"

    response = HTTParty.get(url, timeout: 30)

    if response.success?
      parsed = JSON.parse(response.body)
      return { exists: true, deactivated: false, handle: parsed['handle'] }
    else
      # Check error message for deactivated or not found
      error_body = JSON.parse(response.body) rescue {}

      # Bluesky returns "RepoDeactivated" for deactivated accounts
      if error_body['error'] == 'RepoDeactivated'
        return { exists: true, deactivated: true }
      # Bluesky returns "InvalidRequest" with "Could not find user" for non-existent accounts
      elsif error_body['error'] == 'InvalidRequest' && error_body['message']&.include?('Could not find user')
        return { exists: false }
      # Other 404 or 400 errors mean account doesn't exist
      elsif [400, 404].include?(response.code)
        return { exists: false }
      else
        # Unexpected error
        Rails.logger.warn("Unexpected response when checking account: #{response.code} - #{error_body}")
        return { exists: false }
      end
    end
  rescue JSON::ParserError, HTTParty::Error, StandardError => e
    Rails.logger.error("Failed to check account existence: #{e.message}")
    raise "Unable to verify account existence: #{e.message}"
  end
end
