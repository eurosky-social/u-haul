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
  before_action :set_migration, only: [:show, :verify_email, :submit_plc_token, :request_new_plc_token, :reauthenticate, :status, :download_backup, :retry, :export_recovery_data, :retry_failed_blobs]
  before_action :set_security_headers

  # GET /migrations/new
  # Display the migration form where users enter their account details
  def new
    @migration = Migration.new

    # Pre-populate new_pds_host in bound mode
    if EuroskyConfig.bound_mode?
      @migration.new_pds_host = EuroskyConfig::TARGET_PDS_HOST
    end
  end

  # POST /migrations/check_did_on_pds
  # Check if a DID already has an account on a PDS (orphaned account check)
  #
  # Params:
  #   - did: DID to check
  #   - pds_host: PDS host URL
  #
  # Response:
  #   - Success: { exists: true/false, deactivated: true/false (if exists) }
  #   - Failure: { error: 'message' }
  def check_did_on_pds
    did = params[:did]&.strip
    pds_host = params[:pds_host]&.strip
    old_pds_host = params[:old_pds_host]&.strip

    if did.blank?
      render json: { error: 'DID is required' }, status: :bad_request
      return
    end

    if pds_host.blank?
      render json: { error: 'PDS host is required' }, status: :bad_request
      return
    end

    # Normalize PDS host
    pds_host = normalize_pds_host(pds_host)

    # Detect if this is a migration_in (returning to a PDS where the account originally lived).
    # For migration_in, finding the DID on the target PDS is expected and required, not an error.
    is_migration_in = false
    if old_pds_host.present?
      old_normalized = normalize_pds_host(old_pds_host)
      new_host = pds_host.downcase.gsub(%r{https?://}, '')
      old_host = old_normalized.downcase.gsub(%r{https?://}, '')
      # It's a migration_in if target is bsky.social and source is not
      is_migration_in = new_host.include?('bsky.social') && !old_host.include?('bsky.social')
    end

    # Check if repo exists on the PDS
    begin
      url = "#{pds_host}/xrpc/com.atproto.repo.describeRepo"
      Rails.logger.info("Checking if DID #{did} exists on PDS: #{url}?repo=#{did}")
      response = HTTParty.get(url, query: { repo: did }, timeout: 10)

      Rails.logger.info("PDS DID check response: #{response.code} - #{response.body[0..200]}")

      if response.success?
        if is_migration_in
          # For migration_in, an active repo on the target PDS is expected
          Rails.logger.info("DID #{did} has active repo on #{pds_host} (migration_in - expected)")
          render json: { exists: false }
        else
          # Active repo exists (unexpected for migration_out)
          Rails.logger.info("DID #{did} has active repo on #{pds_host}")
          support_email = ENV.fetch('TARGET_PDS_SUPPORT_EMAIL', ENV.fetch('SUPPORT_EMAIL', 'support@example.com'))
          render json: { exists: true, deactivated: false, support_email: support_email }
        end
      elsif response.code == 400
        parsed = JSON.parse(response.body) rescue {}
        if parsed['error'] == 'RepoDeactivated'
          if is_migration_in
            # For migration_in, a deactivated repo is also expected (account was moved away)
            Rails.logger.info("DID #{did} has deactivated repo on #{pds_host} (migration_in - expected)")
            render json: { exists: false }
          else
            # Deactivated/orphaned repo exists (unexpected for migration_out)
            Rails.logger.info("DID #{did} has deactivated repo on #{pds_host}")
            support_email = ENV.fetch('TARGET_PDS_SUPPORT_EMAIL', ENV.fetch('SUPPORT_EMAIL', 'support@example.com'))
            render json: { exists: true, deactivated: true, support_email: support_email }
          end
        else
          # DID doesn't exist
          Rails.logger.info("DID #{did} does not exist on #{pds_host}")
          render json: { exists: false }
        end
      else
        # DID doesn't exist
        Rails.logger.info("DID #{did} does not exist on #{pds_host}")
        render json: { exists: false }
      end
    rescue StandardError => e
      Rails.logger.error("Error checking DID on PDS: #{e.message}")
      render json: { error: "Failed to check PDS" }, status: :internal_server_error
    end
  end

  # POST /migrations/verify_target_credentials
  # Authenticate against the target PDS to verify the user's password (AJAX endpoint)
  # Used for migration_in (returning to bsky.social) where the user must prove
  # they can log in to their existing account on the target PDS.
  #
  # Params:
  #   - pds_host: Target PDS host URL (e.g., https://bsky.social)
  #   - did: The user's DID (used as login identifier)
  #   - password: The user's password on the target PDS
  #
  # Response:
  #   - Success: { success: true, access_token: '...', refresh_token: '...' }
  #   - Failure: { error: 'message' }
  def verify_target_credentials
    pds_host = params[:pds_host]&.strip
    did = params[:did]&.strip
    password = params[:password]&.strip

    if pds_host.blank? || did.blank? || password.blank?
      render json: { error: 'PDS host, DID, and password are required' }, status: :bad_request
      return
    end

    pds_host = normalize_pds_host(pds_host)

    # Authenticate against the target PDS
    session_url = "#{pds_host}/xrpc/com.atproto.server.createSession"
    response = HTTParty.post(
      session_url,
      headers: { 'Content-Type' => 'application/json' },
      body: { identifier: did, password: password }.to_json,
      timeout: 30
    )

    unless response.success?
      error_body = JSON.parse(response.body) rescue {}
      error_msg = error_body['message'] || error_body['error'] || 'Authentication failed'

      if error_msg.include?('Invalid identifier or password')
        render json: { error: "Wrong password for your Bluesky account. Please enter the password you used on bsky.social." }, status: :unauthorized
      else
        render json: { error: "Authentication failed: #{error_msg}" }, status: :unauthorized
      end
      return
    end

    session_data = JSON.parse(response.body)

    render json: {
      success: true,
      access_token: session_data['accessJwt'],
      refresh_token: session_data['refreshJwt']
    }
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse target PDS response: #{e.message}")
    render json: { error: "Invalid response from target PDS" }, status: :internal_server_error
  rescue StandardError => e
    Rails.logger.error("Failed to verify target credentials: #{e.message}")
    render json: { error: "Failed to connect to target PDS. Please try again." }, status: :internal_server_error
  end

  # POST /migrations/check_handle
  # Check if a handle is available on a PDS (AJAX endpoint)
  #
  # Params:
  #   - handle: Full handle to check (e.g., username.eurosky.social)
  #   - pds_host: PDS host URL
  #
  # Response:
  #   - Success: { available: true/false }
  #   - Failure: { error: 'message' }
  def check_handle
    handle = params[:handle]&.strip
    pds_host = params[:pds_host]&.strip
    user_did = params[:did]&.strip  # The authenticated user's DID (for migration_in)

    if handle.blank?
      render json: { error: 'Handle is required' }, status: :bad_request
      return
    end

    if pds_host.blank?
      render json: { error: 'PDS host is required' }, status: :bad_request
      return
    end

    # Normalize PDS host
    pds_host = normalize_pds_host(pds_host)

    # Check 1: Try to resolve the handle via PLC directory
    begin
      resolution = GoatService.resolve_handle(handle)

      # If the handle resolves to the same DID as the authenticated user,
      # it's their own handle — allow them to reclaim it (migration_in scenario)
      if user_did.present? && resolution[:did] == user_did
        Rails.logger.info("Handle #{handle} belongs to the authenticated user (DID: #{user_did}) - available for reclaim")
        render json: { available: true }
        return
      end

      # Handle exists in PLC - check if it's on a different PDS
      if resolution[:pds_host] == pds_host
        # Handle exists on this PDS in PLC - not available
        render json: { available: false }
        return
      end
      # Handle exists on different PDS in PLC - continue to check actual PDS
    rescue GoatService::NetworkError
      # Handle doesn't exist in PLC - continue to check actual PDS
    end

    # Check 2: Query the target PDS directly to check for orphaned accounts
    # This catches accounts that exist in the PDS database but aren't in PLC yet
    begin
      url = "#{pds_host}/xrpc/com.atproto.identity.resolveHandle"
      Rails.logger.info("Checking handle availability on PDS: #{url}?handle=#{handle}")
      response = HTTParty.get(url, query: { handle: handle }, timeout: 10)

      Rails.logger.info("PDS handle check response: #{response.code} - #{response.body[0..200]}")

      if response.success?
        # Handle exists on the PDS — check if it belongs to the authenticated user
        parsed = JSON.parse(response.body) rescue {}
        resolved_did = parsed['did']

        if user_did.present? && resolved_did == user_did
          Rails.logger.info("Handle #{handle} on #{pds_host} belongs to authenticated user (DID: #{user_did}) - available for reclaim")
          render json: { available: true }
        else
          Rails.logger.info("Handle #{handle} exists on #{pds_host} - not available")
          render json: { available: false }
        end
      else
        # Handle doesn't exist on the PDS - available
        Rails.logger.info("Handle #{handle} does not exist on #{pds_host} - available")
        render json: { available: true }
      end
    rescue StandardError => e
      Rails.logger.error("Error checking handle on PDS: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      # If we can't check the PDS, assume it's available (fail open)
      render json: { available: true }
    end
  end

  # POST /migrations/check_pds
  # Check PDS requirements (invite code, etc.) (AJAX endpoint)
  #
  # Params:
  #   - pds_host: PDS host URL (e.g., https://eurosky.social)
  #
  # Response:
  #   - Success: { invite_code_required: true/false, available_user_domains: [...] }
  #   - Failure: { error: 'message' }
  def check_pds
    pds_host = params[:pds_host]&.strip

    if pds_host.blank?
      render json: { error: 'PDS host is required' }, status: :bad_request
      return
    end

    # Normalize PDS host (add https:// if missing)
    pds_host = normalize_pds_host(pds_host)

    # Query the PDS describeServer endpoint
    describe_url = "#{pds_host}/xrpc/com.atproto.server.describeServer"

    response = HTTParty.get(describe_url, timeout: 10)

    unless response.success?
      render json: { error: "Could not connect to PDS. Please check the URL." }, status: :not_found
      return
    end

    server_info = JSON.parse(response.body)

    # Check if invite codes are required
    invite_code_required = server_info['inviteCodeRequired'] || false
    available_user_domains = server_info['availableUserDomains'] || []

    Rails.logger.info("PDS #{pds_host} - Invite code required: #{invite_code_required}")

    render json: {
      invite_code_required: invite_code_required,
      available_user_domains: available_user_domains
    }
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse PDS response: #{e.message}")
    render json: { error: "Invalid response from PDS" }, status: :internal_server_error
  rescue HTTParty::Error, StandardError => e
    Rails.logger.error("Failed to check PDS requirements: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.respond_to?(:backtrace)
    error_message = Rails.env.production? ? "Failed to connect to PDS. Please check the URL." : "Failed to connect to PDS: #{e.message}"
    render json: { error: error_message }, status: :internal_server_error
  end

  # POST /migrations/lookup_handle
  # Authenticate and fetch account details (AJAX endpoint)
  #
  # Params:
  #   - handle: AT Protocol handle (e.g., user.bsky.social)
  #   - password: Account password
  #
  # Response:
  #   - Success: { did: '...', email: '...', pds_host: '...' }
  #   - Failure: { error: 'message' }
  def lookup_handle
    handle = params[:handle]&.strip
    password = params[:password]&.strip

    if handle.blank?
      render json: { error: 'Handle is required' }, status: :bad_request
      return
    end

    if password.blank?
      render json: { error: 'Password is required' }, status: :bad_request
      return
    end

    # Sanitize handle
    handle = sanitize_handle(handle)

    # Detect handle type (DNS-verified custom domain vs PDS-hosted)
    handle_info = GoatService.detect_handle_type(handle)

    # Resolve handle to DID and PDS
    resolution = GoatService.resolve_handle(handle)
    pds_host = resolution[:pds_host]
    did = resolution[:did]

    # Authenticate and get session to fetch email
    account_details = authenticate_and_fetch_profile(pds_host, handle, password)

    render json: {
      did: did,
      pds_host: pds_host,
      email: account_details[:email],
      handle: account_details[:handle],
      access_token: account_details[:access_token],
      refresh_token: account_details[:refresh_token],
      handle_type: handle_info[:type],
      handle_verified_via: handle_info[:verified_via],
      can_preserve_handle: handle_info[:can_preserve],
      handle_preservation_note: handle_info[:reason]
    }
  rescue GoatService::NetworkError => e
    Rails.logger.error("Failed to resolve handle #{handle}: #{e.message}")
    render json: { error: "Could not resolve handle. Please check that the handle is correct." }, status: :not_found
  rescue AuthenticationError => e
    Rails.logger.error("Authentication failed for handle #{handle}: #{e.message}")
    render json: { error: "Authentication failed. Please check your password." }, status: :unauthorized
  rescue StandardError => e
    Rails.logger.error("Unexpected error during handle lookup: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    error_message = Rails.env.production? ? "An unexpected error occurred. Please try again." : "An unexpected error occurred: #{e.message}"
    render json: { error: error_message }, status: :internal_server_error
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
      # Sanitize ALL user inputs by removing invisible Unicode characters and trimming whitespace
      @migration.old_handle = sanitize_user_input(@migration.old_handle) if @migration.old_handle.present?
      @migration.new_handle = sanitize_user_input(@migration.new_handle) if @migration.new_handle.present?
      @migration.email = sanitize_user_input(@migration.email) if @migration.email.present?
      @migration.new_pds_host = sanitize_user_input(@migration.new_pds_host) if @migration.new_pds_host.present?

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

      # Retrieve the old PDS tokens from the AJAX authentication (stored in hidden fields)
      # These tokens were obtained during the lookup_handle step
      old_access_token = params[:migration][:old_access_token]
      old_refresh_token = params[:migration][:old_refresh_token]

      if old_access_token.blank? || old_refresh_token.blank?
        @migration.errors.add(:base, "Authentication tokens are missing. Please go back and re-authenticate.")
        render :new, status: :unprocessable_entity
        return
      end

      @migration.credentials_expires_at = 48.hours.from_now

      # Store old PDS tokens (encrypted via Lockbox)
      @migration.old_access_token = old_access_token
      @migration.old_refresh_token = old_refresh_token

      @migration.progress_data ||= {}

      if @migration.migration_type == 'migration_in'
        # For migration_in, store the target PDS tokens (verified in the wizard)
        new_access_token = params[:migration][:new_access_token]
        new_refresh_token = params[:migration][:new_refresh_token]

        if new_access_token.blank? || new_refresh_token.blank?
          @migration.errors.add(:base, "Target PDS authentication tokens are missing. Please go back and verify your bsky.social credentials.")
          render :new, status: :unprocessable_entity
          return
        end

        @migration.new_access_token = new_access_token
        @migration.new_refresh_token = new_refresh_token

        # No generated password for migration_in — the user keeps their existing password
        Rails.logger.info("Migration_in: stored target PDS tokens for #{@migration.new_pds_host}")
      else
        # For migration_out, generate a secure random password for the new account
        # This will be emailed to the user after migration completes (NOT immediately)
        new_account_password = SecureRandom.urlsafe_base64(16) # ~128 bits of entropy
        @migration.password = new_account_password  # Lockbox encrypts this

        # Track password generation time (for auditing), but NOT the password itself
        @migration.progress_data['password_generated_at'] = Time.current.iso8601
      end

      # Set the invite code if provided and enabled (Lockbox encrypts automatically)
      if EuroskyConfig.invite_code_enabled? && params[:migration][:invite_code].present?
        @migration.invite_code = params[:migration][:invite_code]
        @migration.invite_code_expires_at = 48.hours.from_now
      end

      if @migration.save
        # Migration saved successfully, token generated
        # Password email is deferred until migration completes (sent from ActivateAccountJob)

        redirect_to migration_by_token_path(@migration.token),
                    notice: "Migration started! You'll receive your new account password by email once migration completes. Track your progress with token: #{@migration.token}"
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

  # GET /migrate/:token/verify/:verification_token
  # Verify email address and start the migration
  #
  # Response:
  #   - Success: Redirects to status page with notice, starts migration
  #   - Failure: Redirects to status page with error
  def verify_email
    verification_token = params[:verification_token]

    if @migration.verify_email!(verification_token)
      Rails.logger.info("Email verified for migration #{@migration.token}, starting migration")
      redirect_to migration_by_token_path(@migration.token),
                  notice: "Email verified! Your migration has started."
    else
      Rails.logger.warn("Invalid email verification token for migration #{@migration.token}")
      redirect_to migration_by_token_path(@migration.token),
                  alert: "Invalid or expired verification link."
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
  #   - plc_otp: The one-time password sent via email for verification
  #
  # Response:
  #   - Success: Redirects to status page with success message
  #   - Failure: Redirects to status page with error message
  def submit_plc_token
    plc_token = params[:plc_token]

    if plc_token.blank?
      Rails.logger.warn("PLC token submission failed for migration #{@migration.token}: Token blank")
      redirect_to migration_by_token_path(@migration.token),
                  alert: "PLC token cannot be blank"
      return
    end

    # Store the encrypted PLC token with expiration
    @migration.set_plc_token(plc_token)
    Rails.logger.info("PLC token accepted for migration #{@migration.token}")

    # Trigger the critical UpdatePlcJob to update the PLC directory
    UpdatePlcJob.perform_later(@migration.id)

    redirect_to migration_by_token_path(@migration.token),
                notice: "PLC token submitted! Your DID will be updated shortly."
  rescue StandardError => e
    Rails.logger.error("Failed to submit PLC token for migration #{@migration.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: "Failed to submit PLC token. Please try again."
  end

  # POST /migrations/:id/request_new_plc_token
  # POST /migrate/:token/request_new_plc_token
  # Request a new PLC token from the old PDS provider
  def request_new_plc_token
    # Allow requesting new token if:
    # 1. Migration is in pending_plc status, OR
    # 2. Migration failed with a PLC-related error (and rotation_key is blank, meaning PLC wasn't updated yet)
    plc_related_failure = @migration.failed? && @migration.last_error&.match?(/PLC|token/i) && @migration.rotation_key.blank?

    unless @migration.status == 'pending_plc' || plc_related_failure
      Rails.logger.warn("PLC token request failed for migration #{@migration.token}: Not in correct status (status: #{@migration.status}, has rotation_key: #{@migration.rotation_key.present?})")
      redirect_to migration_by_token_path(@migration.token),
                  alert: "Cannot request a new PLC token at this stage. The PLC update may have already been attempted."
      return
    end

    # Check if we still have old PDS tokens to make the API call
    has_old_tokens = @migration.encrypted_old_refresh_token.present?

    if has_old_tokens
      begin
        # Request a new PLC token from the old PDS
        service = GoatService.new(@migration)
        service.request_plc_token

        # Update progress to indicate token was requested
        @migration.progress_data ||= {}
        @migration.progress_data['plc_token_requested_at'] = Time.current.iso8601
        @migration.progress_data['plc_token_resent'] = true
        @migration.save!

        notice_msg = "A new PLC token has been requested. Check your email from #{@migration.old_pds_host}."
      rescue StandardError => e
        Rails.logger.error("Failed to request new PLC token for migration #{@migration.token}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))

        # Even if the API call failed, reset to pending_plc so the user can
        # manually enter a token they request through other means
        notice_msg = "Could not automatically request a new PLC token (#{e.message}). " \
                     "Please request one manually through your old PDS provider's settings (e.g., Bluesky app → Settings → Account → Request PLC Token), " \
                     "then enter it below."
      end
    else
      # Old PDS tokens are no longer available (expired or cleared).
      # Reset to pending_plc and instruct the user to request the token manually.
      Rails.logger.info("Old PDS tokens unavailable for migration #{@migration.token}, resetting to pending_plc for manual token entry")
      notice_msg = "Your session with #{@migration.old_pds_host} has expired. " \
                   "Please request a new PLC token manually: log in to your old account and go to Settings → Account → Request PLC Token, " \
                   "then enter the token below."
    end

    # Reset to pending_plc status so user can submit the new token
    if @migration.failed?
      @migration.update!(status: 'pending_plc', last_error: nil, current_job_attempt: 0)
      Rails.logger.info("Reset migration #{@migration.token} from failed to pending_plc after PLC token request")
    end

    redirect_to migration_by_token_path(@migration.token), notice: notice_msg
  end

  # POST /migrate/:token/reauthenticate
  # Re-authenticate with the old PDS to get fresh tokens for PLC token request.
  # Used when old PDS session tokens have expired or been cleaned up.
  def reauthenticate
    password = params[:password]&.strip

    if password.blank?
      redirect_to migration_by_token_path(@migration.token), alert: "Password is required."
      return
    end

    # Only allow re-auth for migrations that need PLC tokens
    plc_related = @migration.pending_plc? || (@migration.failed? && @migration.rotation_key.blank?)
    unless plc_related
      redirect_to migration_by_token_path(@migration.token),
                  alert: "Re-authentication is not available at this stage."
      return
    end

    begin
      # Authenticate with the old PDS
      session_url = "#{@migration.old_pds_host}/xrpc/com.atproto.server.createSession"
      response = HTTParty.post(
        session_url,
        headers: { 'Content-Type' => 'application/json' },
        body: { identifier: @migration.old_handle, password: password }.to_json,
        timeout: 30
      )

      unless response.success?
        error_body = JSON.parse(response.body) rescue {}
        error_msg = error_body['message'] || 'Authentication failed'
        redirect_to migration_by_token_path(@migration.token),
                    alert: "Authentication failed: #{error_msg}. Please check your password."
        return
      end

      session_data = JSON.parse(response.body)

      # Store fresh tokens (with 48h expiry)
      @migration.set_old_pds_tokens!(
        access_token: session_data['accessJwt'],
        refresh_token: session_data['refreshJwt']
      )

      # Also re-store the password — it's needed for logging in to the new PDS
      # during the PLC update step (the new PDS account uses the same password).
      @migration.password = password
      @migration.save!

      Rails.logger.info("Re-authenticated with old PDS for migration #{@migration.token}")

      # Check if we already have a valid (non-expired) PLC token.
      # If so, skip requesting a new one and directly retry the PLC update.
      if !@migration.plc_token_expired? && @migration.encrypted_plc_token.present?
        Rails.logger.info("Valid PLC token still present for #{@migration.token} — retrying PLC update directly")

        @migration.update!(status: 'pending_plc', last_error: nil, current_job_attempt: 0) if @migration.failed?
        UpdatePlcJob.perform_later(@migration.id)
        notice_msg = "Re-authenticated successfully! Your PLC token is still valid — retrying the PLC update now."
      else
        # No valid PLC token — request a new one
        begin
          service = GoatService.new(@migration)
          service.request_plc_token
          notice_msg = "Re-authenticated successfully! A new PLC token has been requested — check your email from #{@migration.old_pds_host}."
        rescue StandardError => e
          Rails.logger.error("Failed to request PLC token after re-auth for #{@migration.token}: #{e.message}")
          notice_msg = "Re-authenticated successfully, but could not request PLC token automatically (#{e.message}). " \
                       "You can request one manually through your old PDS provider's settings, then enter it below."
        end

        # Reset to pending_plc so the PLC token form appears
        if @migration.failed?
          @migration.update!(status: 'pending_plc', last_error: nil, current_job_attempt: 0)
        end
      end

      redirect_to migration_by_token_path(@migration.token), notice: notice_msg

    rescue StandardError => e
      Rails.logger.error("Re-authentication failed for migration #{@migration.token}: #{e.message}")
      redirect_to migration_by_token_path(@migration.token),
                  alert: "Failed to re-authenticate: #{e.message}"
    end
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

  # POST /migrate/:token/resend_otp
  # POST /migrations/:id/resend_plc_otp
  # Resend the PLC OTP verification code
  #
  # Requirements:
  #   - Migration must be in pending_plc status
  #   - Rate limited to prevent abuse
  #
  # Response:
  #   - Success: Redirects to status page with notice
  #   - Failure: Redirects to status page with alert

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
                alert: "Failed to retry migration. Please try again."
  end

  # POST /migrate/:token/retry_failed_blobs
  # Retry only the blobs that failed during the initial transfer
  #
  # Requirements:
  #   - Migration must have failed blobs in progress_data
  #   - Migration should be completed or in pending_blobs state
  #
  # Response:
  #   - Success: Redirects to status page with notice
  #   - Failure: Redirects to status page with alert
  def retry_failed_blobs
    failed_blobs = @migration.progress_data&.dig('failed_blobs') || []

    if failed_blobs.empty?
      redirect_to migration_by_token_path(@migration.token),
                  alert: "No failed blobs to retry"
      return
    end

    # Enqueue job to retry just the failed blobs
    RetryFailedBlobsJob.perform_later(@migration.id, failed_blobs)

    Rails.logger.info("Retry failed blobs requested for migration #{@migration.token} (#{failed_blobs.length} blobs)")
    redirect_to migration_by_token_path(@migration.token),
                notice: "Retrying #{failed_blobs.length} failed blobs..."
  rescue StandardError => e
    Rails.logger.error("Failed to retry failed blobs for migration #{@migration.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: "Failed to retry blobs: #{e.message}"
  end

  # GET /migrate/:token/export_recovery_data
  # Export all migration data for recovery/debugging
  #
  # Formats:
  #   - JSON: Complete migration data including progress, errors, metadata
  #   - TXT: Failed blobs manifest (if applicable)
  #
  # Response:
  #   - Success: Returns recovery data in requested format
  #   - Failure: Returns 500 with error message
  def export_recovery_data
    respond_to do |format|
      format.json do
        recovery_data = {
          migration_token: @migration.token,
          did: @migration.did,
          old_handle: @migration.old_handle,
          new_handle: @migration.new_handle,
          old_pds_host: @migration.old_pds_host,
          new_pds_host: @migration.new_pds_host,
          email: @migration.email,
          status: @migration.status,
          migration_type: @migration.migration_type,
          created_at: @migration.created_at.iso8601,
          updated_at: @migration.updated_at.iso8601,
          progress_percentage: @migration.progress_percentage,
          estimated_memory_mb: @migration.estimated_memory_mb,
          progress_data: @migration.progress_data,
          last_error: @migration.last_error,
          retry_count: @migration.retry_count,
          current_job_step: @migration.current_job_step,
          current_job_attempt: @migration.current_job_attempt,
          current_job_max_attempts: @migration.current_job_max_attempts,
          failed_blobs: @migration.progress_data&.dig('failed_blobs') || [],
          rotation_key_available: @migration.rotation_key.present?,
          backup_available: @migration.backup_available?,
          credentials_expired: @migration.credentials_expired?
        }

        # Add rotation key if available (SECURITY: Only in recovery data)
        if @migration.rotation_key.present?
          recovery_data[:rotation_key] = @migration.rotation_key
          recovery_data[:rotation_key_warning] = "SAVE THIS SECURELY - This is your only account recovery mechanism"
        end

        render json: recovery_data, status: :ok
      end

      format.txt do
        # Generate failed blobs manifest
        failed_blobs = @migration.progress_data&.dig('failed_blobs') || []

        manifest = <<~MANIFEST
          MIGRATION RECOVERY DATA
          =======================

          Migration Token: #{@migration.token}
          DID: #{@migration.did}
          Status: #{@migration.status}
          Date: #{Time.current.iso8601}

          Old PDS: #{@migration.old_pds_host}
          Old Handle: #{@migration.old_handle}

          New PDS: #{@migration.new_pds_host}
          New Handle: #{@migration.new_handle}

          ---

          FAILED BLOBS REPORT
          ===================

          Total Failed Blobs: #{failed_blobs.length}

        MANIFEST

        if failed_blobs.any?
          manifest += "\nFailed Blob CIDs:\n"
          failed_blobs.each_with_index do |cid, index|
            manifest += "  #{index + 1}. #{cid}\n"
          end

          manifest += <<~FOOTER

            ---

            RECOVERY INSTRUCTIONS
            =====================

            These blobs were downloaded from the old PDS but failed to upload
            to the new PDS due to network errors or timeouts.

            To retry these blobs:
            1. Use the "Retry Failed Blobs" button on the status page
            2. Or manually upload using the goat CLI:
               goat blob upload --pds-host #{@migration.new_pds_host} <blob-file>

            For assistance, contact support with this migration token:
            #{@migration.token}
          FOOTER
        else
          manifest += "\nNo failed blobs - all blobs transferred successfully!\n"
        end

        # Add error information if present
        if @migration.last_error.present?
          manifest += <<~ERROR_INFO

            ---

            ERROR INFORMATION
            =================

            Last Error: #{@migration.last_error}
            Job Step: #{@migration.current_job_step || 'Unknown'}
            Retry Count: #{@migration.retry_count}

          ERROR_INFO
        end

        send_data manifest,
                  filename: "migration-recovery-#{@migration.token}.txt",
                  type: 'text/plain',
                  disposition: 'attachment'
      end

      format.all do
        render plain: "Format not supported. Use .json or .txt", status: :not_acceptable
      end
    end
  rescue StandardError => e
    Rails.logger.error("Failed to export recovery data for migration #{@migration.token}: #{e.message}")

    respond_to do |format|
      format.json { render json: { error: "Failed to export recovery data: #{e.message}" }, status: :internal_server_error }
      format.txt { render plain: "Failed to export recovery data: #{e.message}", status: :internal_server_error }
      format.all { render plain: "Failed to export recovery data: #{e.message}", status: :internal_server_error }
    end
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
  # The old_access_token, old_refresh_token, invite_code, old_pds_host, and did are handled separately and not mass-assigned
  # old_pds_host and did are automatically resolved from the old_handle
  def migration_params
    allowed = [:email, :old_handle, :new_handle, :create_backup_bundle]

    # Add new_pds_host only in standalone mode
    allowed << :new_pds_host if EuroskyConfig.standalone_mode?

    # Include tokens and invite_code in permitted params to avoid unpermitted parameter warnings
    # These are accessed directly in the create action (not mass-assigned) for encryption handling
    allowed << :old_access_token
    allowed << :old_refresh_token
    allowed << :new_access_token
    allowed << :new_refresh_token
    allowed << :invite_code if EuroskyConfig.invite_code_enabled?

    params.require(:migration).permit(*allowed)
  end

  # Format migration data for JSON API response
  # Includes all relevant status information for client-side polling
  def migration_status_json
    blob_data = calculate_blob_statistics

    {
      token: @migration.token,
      status: @migration.status,
      status_humanized: @migration.status.humanize,
      progress_percentage: @migration.progress_percentage,
      estimated_time_remaining: @migration.estimated_time_remaining,
      blob_count: blob_data[:count],
      blobs_uploaded: blob_data[:uploaded],
      total_bytes_transferred: blob_data[:bytes_transferred],
      last_error: @migration.last_error,
      completed: @migration.completed?,
      failed: @migration.failed?,
      job_retrying: @migration.job_retrying?,
      current_job_step: @migration.current_job_step,
      current_job_attempt: @migration.current_job_attempt,
      current_job_max_attempts: @migration.current_job_max_attempts,
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

  # Sanitize user input by removing invisible Unicode characters and trimming whitespace
  # This prevents issues with copy-pasted text that may contain RTL marks, zero-width spaces, etc.
  def sanitize_user_input(input)
    return nil if input.nil?

    # Remove common invisible Unicode characters:
    # - U+200B: Zero-width space
    # - U+200C: Zero-width non-joiner
    # - U+200D: Zero-width joiner
    # - U+200E: Left-to-right mark
    # - U+200F: Right-to-left mark
    # - U+202A-U+202E: Various directional formatting characters
    # - U+FEFF: Zero-width no-break space (BOM)
    # - U+00A0: Non-breaking space
    input.gsub(/[\u200B-\u200F\u202A-\u202E\uFEFF\u00A0]/, '').strip
  end

  # Alias for backwards compatibility
  def sanitize_handle(handle)
    sanitize_user_input(handle)
  end

  # Normalize PDS host URL (ensure https:// prefix)
  def normalize_pds_host(host)
    return nil if host.nil?

    host = host.strip
    # Add https:// if no protocol is specified
    host = "https://#{host}" unless host.start_with?('http://', 'https://')
    # Remove trailing slash
    host = host.chomp('/')

    host
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

  # Custom error class for authentication failures
  class AuthenticationError < StandardError; end

  # Authenticate and fetch profile with email
  # Requires valid credentials to access private account information
  def authenticate_and_fetch_profile(pds_host, identifier, password)
    # Create session to authenticate
    session_url = "#{pds_host}/xrpc/com.atproto.server.createSession"

    response = HTTParty.post(
      session_url,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        identifier: identifier,
        password: password
      }.to_json,
      timeout: 30
    )

    unless response.success?
      error_body = JSON.parse(response.body) rescue {}
      error_message = error_body['message'] || error_body['error'] || 'Authentication failed'
      raise AuthenticationError, error_message
    end

    session_data = JSON.parse(response.body)

    email = session_data['email']
    handle = session_data['handle']

    Rails.logger.info("Successfully authenticated #{identifier}, email: #{email.present? ? 'present' : 'not available'}")

    {
      handle: handle,
      email: email,
      access_token: session_data['accessJwt'],
      refresh_token: session_data['refreshJwt']
    }
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse authentication response: #{e.message}")
    raise AuthenticationError, "Invalid response from server"
  rescue HTTParty::Error => e
    Rails.logger.error("Network error during authentication: #{e.message}")
    raise AuthenticationError, "Network error: #{e.message}"
  end

  # Set security headers to prevent indexing and caching of sensitive migration data
  # These headers provide defense-in-depth alongside robots.txt and meta tags
  def set_security_headers
    # Prevent search engine indexing via HTTP header
    response.headers['X-Robots-Tag'] = 'noindex, nofollow, noarchive, nosnippet'

    # Prevent caching of sensitive migration status pages
    response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, private, max-age=0'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'

    # Security headers
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['X-XSS-Protection'] = '1; mode=block'

    # Referrer policy - don't leak migration tokens in referrer
    response.headers['Referrer-Policy'] = 'no-referrer'
  end
end
