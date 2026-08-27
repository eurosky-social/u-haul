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
  before_action :set_migration, only: [:show, :verify_email, :resend_verification, :submit_plc_token, :request_new_plc_token, :reauthenticate, :status, :download_backup, :retry, :export_recovery_data, :retry_failed_blobs, :confirm_delete, :request_cancellation, :confirm_cancellation]
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
  # Check if a DID already has an account on a PDS
  #
  # Params:
  #   - did: DID to check
  #   - pds_host: PDS host URL
  #
  # Response:
  #   - Success: { exists: true/false, deactivated: true/false (if exists), support_email: '...' }
  #   - Failure: { error: 'message' }
  def check_did_on_pds
    did = params[:did]&.strip
    pds_host = params[:pds_host]&.strip

    if did.blank?
      render json: { error: I18n.t('controllers.migrations.did_required') }, status: :bad_request
      return
    end

    if pds_host.blank?
      render json: { error: I18n.t('controllers.migrations.pds_required') }, status: :bad_request
      return
    end

    # Normalize PDS host
    pds_host = normalize_pds_host(pds_host)

    # Check if repo exists on the PDS
    begin
      url = "#{pds_host}/xrpc/com.atproto.repo.describeRepo"
      Rails.logger.info("Checking if DID #{did} exists on PDS: #{url}?repo=#{did}")
      response = HTTParty.get(url, query: { repo: did }, timeout: 10)

      Rails.logger.info("PDS DID check response: #{response.code} - #{response.body[0..200]}")

      if response.success?
        parsed = JSON.parse(response.body) rescue {}
        handle = parsed['handle']
        Rails.logger.info("DID #{did} has active repo on #{pds_host} (handle: #{handle})")
        render json: { exists: true, deactivated: false, handle: handle }
      elsif response.code == 400
        parsed = JSON.parse(response.body) rescue {}
        if parsed['error'] == 'RepoDeactivated'
          Rails.logger.info("DID #{did} has deactivated repo on #{pds_host}")
          render json: { exists: true, deactivated: true }
        else
          Rails.logger.info("DID #{did} does not exist on #{pds_host}")
          render json: { exists: false }
        end
      else
        Rails.logger.info("DID #{did} does not exist on #{pds_host}")
        render json: { exists: false }
      end
    rescue StandardError => e
      Rails.logger.error("Error checking DID on PDS: #{e.message}")
      render json: { error: I18n.t('controllers.migrations.pds_connect_failed') }, status: :internal_server_error
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
      render json: { error: I18n.t('controllers.migrations.pds_did_password_required') }, status: :bad_request
      return
    end

    pds_host = normalize_pds_host(pds_host)
    two_factor_code = params[:two_factor_code]&.strip

    # Authenticate against the target PDS
    session_url = "#{pds_host}/xrpc/com.atproto.server.createSession"

    body = { identifier: did, password: password }
    body[:authFactorToken] = two_factor_code if two_factor_code.present?

    response = HTTParty.post(
      session_url,
      headers: { 'Content-Type' => 'application/json' },
      body: body.to_json,
      timeout: 30
    )

    unless response.success?
      error_body = JSON.parse(response.body) rescue {}

      # Check for 2FA requirement
      if error_body['error'] == 'AuthFactorTokenRequired'
        render json: { two_factor_required: true, error: I18n.t('controllers.migrations.two_factor_required') }, status: :unauthorized
        return
      end

      error_msg = error_body['message'] || error_body['error'] || 'Authentication failed'

      if error_msg.include?('Invalid identifier or password')
        render json: { error: I18n.t('controllers.migrations.wrong_password') }, status: :unauthorized
      else
        render json: { error: I18n.t('controllers.migrations.auth_failed', error: error_msg) }, status: :unauthorized
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
    render json: { error: I18n.t('controllers.migrations.invalid_pds_response') }, status: :internal_server_error
  rescue StandardError => e
    Rails.logger.error("Failed to verify target credentials: #{e.message}")
    render json: { error: I18n.t('controllers.migrations.pds_connect_failed') }, status: :internal_server_error
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
    handle = GoatService.clean_handle(params[:handle])
    pds_host = params[:pds_host]&.strip
    user_did = params[:did]&.strip  # The authenticated user's DID (for migration_in)

    if handle.blank?
      render json: { error: I18n.t('controllers.migrations.handle_required') }, status: :bad_request
      return
    end

    if pds_host.blank?
      render json: { error: I18n.t('controllers.migrations.pds_required') }, status: :bad_request
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
    rescue GoatService::HandleNotFoundError, GoatService::NetworkError
      # Either the handle isn't in PLC, or we couldn't reach PLC to ask.
      # Both fall through to querying the target PDS directly below.
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
      render json: { error: I18n.t('controllers.migrations.pds_required') }, status: :bad_request
      return
    end

    # Normalize PDS host (add https:// if missing)
    pds_host = normalize_pds_host(pds_host)

    # Query the PDS describeServer endpoint
    describe_url = "#{pds_host}/xrpc/com.atproto.server.describeServer"

    response = HTTParty.get(describe_url, timeout: 10)

    unless response.success?
      render json: { error: I18n.t('controllers.migrations.pds_connect_check') }, status: :not_found
      return
    end

    server_info = JSON.parse(response.body)

    # Check if invite codes are required
    invite_code_required = server_info['inviteCodeRequired'] || false
    captcha_required = server_info['phoneVerificationRequired'] || false
    available_user_domains = server_info['availableUserDomains'] || []
    contact_email = server_info.dig('contact', 'email')
    tos_url = server_info.dig('links', 'termsOfService')
    privacy_policy_url = server_info.dig('links', 'privacyPolicy')

    # If captcha required, fetch the hCaptcha site key from the gatekeeper's signup page
    captcha_site_key = nil
    if captcha_required
      captcha_site_key = fetch_captcha_site_key(pds_host)
      Rails.logger.info("PDS #{pds_host} - captcha site key: #{captcha_site_key || 'not found'}")
    end

    # Check if this is an Eurosky PDS (only show consent UI for Eurosky)
    is_eurosky = is_eurosky_pds?(pds_host)

    Rails.logger.info("PDS #{pds_host} - Invite code required: #{invite_code_required}, captcha: #{captcha_required}, is_eurosky: #{is_eurosky}, contact: #{contact_email || 'none'}, tos: #{tos_url || 'none'}, privacy: #{privacy_policy_url || 'none'}")

    render json: {
      invite_code_required: invite_code_required,
      captcha_required: captcha_required,
      captcha_site_key: captcha_site_key,
      available_user_domains: available_user_domains,
      contact_email: contact_email,
      tos_url: tos_url,
      privacy_policy_url: privacy_policy_url,
      is_eurosky: is_eurosky
    }
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse PDS response: #{e.message}")
    render json: { error: I18n.t('controllers.migrations.invalid_pds_response') }, status: :internal_server_error
  rescue HTTParty::Error, StandardError => e
    Rails.logger.error("Failed to check PDS requirements: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.respond_to?(:backtrace)
    error_message = Rails.env.production? ? I18n.t('controllers.migrations.pds_connect_check') : "Failed to connect to PDS: #{e.message}"
    render json: { error: error_message }, status: :internal_server_error
  end

  # GET /migrations/search_actors
  # Typeahead search for ATProto actors via the public Bluesky AppView API
  #
  # Params:
  #   - q: Search query (minimum 2 characters)
  #   - limit: Max results (default 8, max 25)
  #
  # Response:
  #   - Success: { actors: [{ handle: '...', display_name: '...', avatar: '...' }, ...] }
  #   - Failure: { actors: [] }
  def search_actors
    query = params[:q]&.strip
    limit = [(params[:limit] || 8).to_i, 25].min

    if query.blank? || query.length < 2
      render json: { actors: [] }
      return
    end

    appview_url = "https://public.api.bsky.app/xrpc/app.bsky.actor.searchActorsTypeahead"
    response = HTTParty.get(appview_url, query: { q: query, limit: limit }, timeout: 5)

    if response.success?
      data = JSON.parse(response.body)
      actors = (data['actors'] || []).map do |actor|
        {
          handle: actor['handle'],
          display_name: actor['displayName'],
          avatar: actor['avatar']
        }
      end
      render json: { actors: actors }
    else
      render json: { actors: [] }
    end
  rescue StandardError => e
    Rails.logger.warn("Actor search failed: #{e.message}")
    render json: { actors: [] }
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
      render json: { error: I18n.t('controllers.migrations.handle_required') }, status: :bad_request
      return
    end

    if password.blank?
      render json: { error: I18n.t('controllers.migrations.password_required') }, status: :bad_request
      return
    end

    # Sanitize handle (strip whitespace, remove @, remove bidi chars, downcase)
    handle = GoatService.clean_handle(handle)

    # Detect handle type (DNS-verified custom domain vs PDS-hosted)
    handle_info = GoatService.detect_handle_type(handle)

    # Resolve handle to DID and PDS
    resolution = GoatService.resolve_handle(handle)
    pds_host = resolution[:pds_host]
    did = resolution[:did]

    # Authenticate and get session to fetch email
    two_factor_code = params[:two_factor_code]&.strip
    account_details = authenticate_and_fetch_profile(pds_host, handle, password, auth_factor_token: two_factor_code)

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
  rescue GoatService::TwoFactorRequiredError => e
    Rails.logger.info("2FA required for handle #{handle}: #{e.message}")
    render json: { two_factor_required: true, error: e.message }, status: :unauthorized
  rescue GoatService::HandleNotFoundError => e
    Rails.logger.info("Handle not found: #{handle}: #{e.message}")
    render json: { error: I18n.t('controllers.migrations.resolve_failed') }, status: :not_found
  rescue GoatService::NetworkError => e
    # Not the user's fault: we could not reach DNS or the directories to ask.
    # Answering 404 "check that the handle is correct" here sent users hunting
    # for a typo that did not exist through the whole 2026-08-21 outage.
    Rails.logger.error("Handle resolution unavailable for #{handle}: #{e.message}")
    render json: { error: I18n.t('controllers.migrations.resolve_unavailable') },
           status: :service_unavailable
  rescue AuthenticationError => e
    Rails.logger.error("Authentication failed for handle #{handle}: #{e.message}")
    error_msg = e.message == I18n.t('controllers.migrations.app_password_not_allowed') ? e.message : I18n.t('controllers.migrations.auth_check_failed')
    render json: { error: error_msg }, status: :unauthorized
  rescue StandardError => e
    Rails.logger.error("Unexpected error during handle lookup: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    error_message = Rails.env.production? ? I18n.t('controllers.migrations.unexpected_error') : I18n.t('controllers.migrations.unexpected_error_detail', error: e.message)
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
      # Handles get additional sanitization (@ prefix removal, bidi char stripping, downcasing)
      @migration.old_handle = GoatService.clean_handle(@migration.old_handle) if @migration.old_handle.present?
      @migration.new_handle = GoatService.clean_handle(@migration.new_handle) if @migration.new_handle.present?
      @migration.email = sanitize_user_input(@migration.email) if @migration.email.present?
      @migration.new_pds_host = sanitize_user_input(@migration.new_pds_host) if @migration.new_pds_host.present?

      # Store the target PDS contact email (fetched from describeServer during wizard)
      target_contact = params[:migration][:target_pds_contact_email]&.strip
      @migration.target_pds_contact_email = target_contact if target_contact.present?

      # Resolve the old handle to get DID and PDS host
      if @migration.old_handle.present?
        resolution = GoatService.resolve_handle(@migration.old_handle)
        @migration.did = resolution[:did]
        @migration.old_pds_host = resolution[:pds_host]

        Rails.logger.info("Resolved handle #{@migration.old_handle}: DID=#{@migration.did}, PDS=#{@migration.old_pds_host}")
      end

      # Detect migration type based on whether the user authenticated with an existing
      # account on the target PDS (indicated by presence of new PDS tokens from the wizard).
      # This works for any PDS, not just bsky.social.
      new_access_token_param = params[:migration][:new_access_token]
      new_refresh_token_param = params[:migration][:new_refresh_token]

      if new_access_token_param.present? && new_refresh_token_param.present?
        @migration.migration_type = 'migration_in'
        Rails.logger.info("Auto-detected migration_in (existing account on target PDS: #{@migration.new_pds_host})")

        # Safety check: verify the account actually exists on the target PDS
        Rails.logger.info("Verifying pre-existing account on #{@migration.new_pds_host} for DID: #{@migration.did}")
        begin
          account_check = verify_account_exists_on_pds(@migration.new_pds_host, @migration.did)

          unless account_check[:exists]
            @migration.errors.add(:base, I18n.t('controllers.migrations.account_not_found', pds: @migration.new_pds_host, did: @migration.did))
            render :new, status: :unprocessable_entity
            return
          end

          Rails.logger.info("Pre-existing account verified on #{@migration.new_pds_host} (deactivated: #{account_check[:deactivated]}, handle: #{account_check[:handle]})")
        rescue StandardError => e
          Rails.logger.error("Failed to verify pre-existing account on #{@migration.new_pds_host}: #{e.message}")
          @migration.errors.add(:base, I18n.t('controllers.migrations.account_verify_failed', pds: @migration.new_pds_host, error: e.message))
          render :new, status: :unprocessable_entity
          return
        end
      else
        @migration.migration_type = 'migration_out'
        Rails.logger.info("Auto-detected migration_out (creating new account on #{@migration.new_pds_host})")
      end

      # Retrieve the old PDS tokens from the AJAX authentication (stored in hidden fields)
      # These tokens were obtained during the lookup_handle step
      old_access_token = params[:migration][:old_access_token]
      old_refresh_token = params[:migration][:old_refresh_token]

      if old_access_token.blank? || old_refresh_token.blank?
        @migration.errors.add(:base, I18n.t('controllers.migrations.tokens_missing'))
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
          @migration.errors.add(:base, I18n.t('controllers.migrations.target_tokens_missing', pds: @migration.new_pds_host))
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

      # Record whether the target PDS requires captcha (from describeServer phoneVerificationRequired)
      if params[:pds_captcha_required] == '1'
        @migration.progress_data['captcha_required'] = true
        @migration.progress_data['captcha_site_key'] = params[:pds_captcha_site_key] if params[:pds_captcha_site_key].present?
      end

      # Set the invite code if provided and enabled (Lockbox encrypts automatically)
      if EuroskyConfig.invite_code_enabled? && params[:migration][:invite_code].present?
        @migration.invite_code = params[:migration][:invite_code]
        @migration.invite_code_expires_at = 48.hours.from_now
      end

      # Require legal consent (GDPR compliance — must not be pre-ticked, must be explicit)
      unless params[:migration][:legal_consent] == "1"
        @migration.errors.add(:base, I18n.t('controllers.migrations.legal_consent_required'))
        render :new, status: :unprocessable_entity
        return
      end

      # Require PDS consent only for Eurosky PDSs (we are the data controller)
      # For third-party PDSs, legal links are shown as informational only
      pds_tos_url = params[:pds_tos_url].presence
      pds_privacy_url = params[:pds_privacy_policy_url].presence
      if is_eurosky_pds?(@migration.new_pds_host) && (pds_tos_url || pds_privacy_url) && params[:pds_consent] != "1"
        @migration.errors.add(:base, I18n.t('controllers.migrations.pds_consent_required'))
        render :new, status: :unprocessable_entity
        return
      end

      if @migration.save
        # Migration saved successfully, token generated
        # Password email is deferred until migration completes (sent from ActivateAccountJob)

        # Record legal consent (separate table, survives migration deletion for GDPR compliance)
        LegalConsent.create!(
          did: @migration.did,
          migration_token: @migration.token,
          tos_snapshot: LegalSnapshot.current('terms_of_service'),
          privacy_policy_snapshot: LegalSnapshot.current('privacy_policy'),
          ip_address: request.remote_ip,
          accepted_at: Time.current
        )

        # Record PDS consent ONLY for Eurosky migrations
        # For third-party PDSs, we show the consent checkbox (gating mechanism) but don't
        # store consent data, as it would make Eurosky a data controller for foreign PDS compliance
        if is_eurosky_pds?(@migration.new_pds_host) && (pds_tos_url || pds_privacy_url)
          PdsConsent.create!(
            did: @migration.did,
            migration_token: @migration.token,
            pds_host: @migration.new_pds_host,
            tos_url: pds_tos_url,
            privacy_policy_url: pds_privacy_url,
            ip_address: request.remote_ip,
            accepted_at: Time.current
          )
        end

        redirect_to migration_by_token_path(@migration.token),
                    notice: I18n.t('controllers.migrations.verification_sent', email: @migration.email)
      else
        render :new, status: :unprocessable_entity
      end
    rescue GoatService::HandleNotFoundError => e
      Rails.logger.info("Handle not found: #{@migration.old_handle}: #{e.message}")
      @migration.errors.add(:old_handle, I18n.t('controllers.migrations.resolve_failed'))
      render :new, status: :unprocessable_entity
    rescue GoatService::NetworkError => e
      Rails.logger.error("Handle resolution unavailable for #{@migration.old_handle}: #{e.message}")
      @migration.errors.add(:base, I18n.t('controllers.migrations.resolve_unavailable'))
      render :new, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Unexpected error during migration creation: #{e.message}")
      @migration.errors.add(:base, I18n.t('controllers.migrations.unexpected_error'))
      render :new, status: :unprocessable_entity
    end
  end

  # POST /migrate/:token/verify
  # Verify email address via code submission and start the migration
  #
  # Params:
  #   - verification_code: The XXX-XXX code sent to the user's email
  #
  # Response:
  #   - Success: Redirects to status page with notice, starts migration
  #   - Failure: Redirects to status page with error
  def verify_email
    verification_code = params[:verification_code]

    if verification_code.blank?
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.enter_code')
      return
    end

    # Verify hCaptcha if the target PDS requires captcha (per describeServer phoneVerificationRequired)
    if @migration.progress_data&.dig('captcha_required')
      captcha_response = params[:'h-captcha-response']
      if captcha_response.blank?
        redirect_to migration_by_token_path(@migration.token),
                    alert: I18n.t('controllers.migrations.captcha_required')
        return
      end

      gate_code = exchange_captcha_for_gate_code(captcha_response, @migration)
      if gate_code.nil?
        redirect_to migration_by_token_path(@migration.token),
                    alert: I18n.t('controllers.migrations.captcha_failed')
        return
      end

      # Store the gate code so CreateAccountJob can pass it as verificationCode
      @migration.progress_data ||= {}
      @migration.progress_data['hcaptcha_token'] = gate_code
      @migration.save!
    end

    if @migration.verify_email!(verification_code)
      Rails.logger.info("Email verified for migration #{@migration.token}, starting migration")
      redirect_to migration_by_token_path(@migration.token),
                  notice: I18n.t('controllers.migrations.email_verified')
    else
      Rails.logger.warn("Invalid email verification code for migration #{@migration.token}")
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.invalid_code')
    end
  end

  # POST /migrate/:token/resend_verification
  # Resend the email verification code
  #
  # Rate-limited to one resend per 60 seconds. Generates a fresh code each time.
  def resend_verification
    unless @migration.email_verification_token.present? && !@migration.email_verified?
      redirect_to migration_by_token_path(@migration.token)
      return
    end

    # Rate limit: 60 seconds between resends
    last_sent = @migration.progress_data&.dig('verification_email_last_sent_at')
    if last_sent.present? && Time.parse(last_sent) > 60.seconds.ago
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.resend_too_soon')
      return
    end

    @migration.regenerate_email_verification_token!
    @migration.update!(progress_data: @migration.progress_data.merge('verification_email_last_sent_at' => Time.current.iso8601))

    MigrationMailer.email_verification(@migration).deliver_later
    Rails.logger.info("Verification email resent for migration #{@migration.token}")

    redirect_to migration_by_token_path(@migration.token),
                notice: I18n.t('controllers.migrations.verification_resent', email: @migration.email)
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
                  alert: I18n.t('controllers.migrations.plc_blank')
      return
    end

    # Extend credentials expiry to give UpdatePlcJob time to complete.
    # The user is actively engaged (just submitted a token), so it's safe to extend.
    if @migration.credentials_expired?
      Rails.logger.warn("Credentials expired at PLC token submission for migration #{@migration.token} — cannot extend without re-authentication")
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.session_expired')
      return
    end
    @migration.update!(credentials_expires_at: 2.hours.from_now)
    Rails.logger.info("Extended credentials expiry for migration #{@migration.token}")

    # Validate that old PDS tokens are still available (needed for sign_plc_operation)
    unless @migration.has_old_pds_tokens?
      Rails.logger.warn("Old PDS tokens missing at PLC token submission for migration #{@migration.token}")
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.old_session_expired', pds: @migration.old_pds_host)
      return
    end

    # Validate new PDS access is available (needed for get_recommended_plc_operation + submit)
    if @migration.migration_in?
      unless @migration.has_new_pds_tokens?
        Rails.logger.warn("New PDS tokens missing at PLC token submission for migration_in #{@migration.token}")
        redirect_to migration_by_token_path(@migration.token),
                    alert: I18n.t('controllers.migrations.old_session_expired', pds: @migration.new_pds_host)
        return
      end
    else
      if @migration.password.nil?
        Rails.logger.warn("New PDS password missing at PLC token submission for migration #{@migration.token}")
        redirect_to migration_by_token_path(@migration.token),
                    alert: I18n.t('controllers.migrations.credentials_expired')
        return
      end
    end

    # Store the encrypted PLC token with expiration
    @migration.set_plc_token(plc_token)
    Rails.logger.info("PLC token accepted for migration #{@migration.token}")

    # Trigger the critical UpdatePlcJob to update the PLC directory
    UpdatePlcJob.perform_later(@migration.id)

    redirect_to migration_by_token_path(@migration.token),
                notice: I18n.t('controllers.migrations.plc_submitted')
  rescue StandardError => e
    Rails.logger.error("Failed to submit PLC token for migration #{@migration.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: I18n.t('controllers.migrations.unexpected_error')
  end

  # POST /migrations/:id/request_new_plc_token
  # POST /migrate/:token/request_new_plc_token
  # Request a new PLC token from the old PDS provider
  def request_new_plc_token
    # Allow requesting new token if:
    # 1. Migration is in pending_plc status, OR
    # 2. Migration failed with a PLC-related error AND the PLC operation was never actually submitted
    #    (rotation_key may exist — it's generated before submission as a safety net)
    plc_actually_submitted = @migration.progress_data&.dig('plc_operation_submitted_at').present?
    plc_related_failure = @migration.failed? && @migration.last_error&.match?(/PLC|token/i) && !plc_actually_submitted

    unless @migration.status == 'pending_plc' || plc_related_failure
      Rails.logger.warn("PLC token request failed for migration #{@migration.token}: Not in correct status (status: #{@migration.status}, plc_submitted: #{plc_actually_submitted})")
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.plc_not_available')
      return
    end

    # Check if we still have old PDS tokens to make the API call
    # Must check both presence AND expiry — encrypted bytes persist in DB after credentials expire
    if @migration.has_old_pds_tokens?
      begin
        # Request a new PLC token from the old PDS
        service = GoatService.new(@migration)
        service.request_plc_token

        # Update progress to indicate token was requested
        @migration.progress_data ||= {}
        @migration.progress_data['plc_token_requested_at'] = Time.current.iso8601
        @migration.progress_data['plc_token_resent'] = true
        @migration.save!

        notice_msg = I18n.t('controllers.migrations.plc_requested', pds: @migration.old_pds_host)
      rescue StandardError => e
        Rails.logger.error("Failed to request new PLC token for migration #{@migration.token}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))

        # Even if the API call failed, reset to pending_plc so the user can
        # manually enter a token they request through other means
        notice_msg = I18n.t('controllers.migrations.plc_request_failed', error: e.message)
      end
    else
      # Old PDS tokens are no longer available (expired or cleared).
      # Reset to pending_plc and instruct the user to request the token manually.
      Rails.logger.info("Old PDS tokens unavailable for migration #{@migration.token}, resetting to pending_plc for manual token entry")
      notice_msg = I18n.t('controllers.migrations.plc_session_expired', pds: @migration.old_pds_host)
    end

    # Reset to pending_plc status so user can submit the new token.
    # Clear the old (invalid) PLC token so the show page renders the token entry form
    # instead of the "Updating your identity" processing state.
    if @migration.failed?
      @migration.update!(status: 'pending_plc', last_error: nil, error_code: nil, current_job_attempt: 0, encrypted_plc_token: nil)
      Rails.logger.info("Reset migration #{@migration.token} from failed to pending_plc after PLC token request (cleared stale PLC token)")
    end

    redirect_to migration_by_token_path(@migration.token), notice: notice_msg
  end

  # POST /migrate/:token/reauthenticate
  # Re-authenticate with the old PDS to get fresh tokens for PLC token request.
  # Used when old PDS session tokens have expired or been cleaned up.
  def reauthenticate
    password = params[:password]&.strip

    if password.blank?
      redirect_to migration_by_token_path(@migration.token), alert: I18n.t('controllers.migrations.password_required_short')
      return
    end

    # Only allow re-auth for migrations that need PLC tokens
    # A rotation key may already exist (generated before PLC submission as a safety net),
    # so check whether the PLC operation was actually submitted to the directory
    plc_actually_submitted = @migration.progress_data&.dig('plc_operation_submitted_at').present?
    plc_related = @migration.pending_plc? || (@migration.failed? && !plc_actually_submitted)
    unless plc_related
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.reauth_not_available')
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
                    alert: I18n.t('controllers.migrations.reauth_failed', error: error_msg)
        return
      end

      session_data = JSON.parse(response.body)

      # Store fresh tokens (with 48h expiry)
      @migration.set_old_pds_tokens!(
        access_token: session_data['accessJwt'],
        refresh_token: session_data['refreshJwt']
      )

      # NOTE: Do NOT overwrite @migration.password here. This form takes the
      # user's OLD PDS password (used above to log into the old PDS), whereas
      # @migration.password is the freshly generated NEW account password
      # (see #create, SecureRandom.urlsafe_base64). Overwriting it with the old
      # password breaks every later new-PDS login with "Invalid identifier or
      # password". The old password is only needed transiently for the session
      # above; we keep only the resulting tokens.

      Rails.logger.info("Re-authenticated with old PDS for migration #{@migration.token}")

      # Check if we already have a valid (non-expired) PLC token.
      # If so, skip requesting a new one and directly retry the PLC update.
      if !@migration.plc_token_expired? && @migration.encrypted_plc_token.present?
        Rails.logger.info("Valid PLC token still present for #{@migration.token} — retrying PLC update directly")

        @migration.update!(status: 'pending_plc', last_error: nil, error_code: nil, current_job_attempt: 0) if @migration.failed?
        UpdatePlcJob.perform_later(@migration.id)
        notice_msg = I18n.t('controllers.migrations.reauth_success_plc_valid')
      else
        # No valid PLC token — request a new one
        begin
          service = GoatService.new(@migration)
          service.request_plc_token
          notice_msg = I18n.t('controllers.migrations.reauth_success_plc_requested', pds: @migration.old_pds_host)
        rescue StandardError => e
          Rails.logger.error("Failed to request PLC token after re-auth for #{@migration.token}: #{e.message}")
          notice_msg = I18n.t('controllers.migrations.reauth_success_plc_failed', error: e.message)
        end

        # Reset to pending_plc so the PLC token form appears
        if @migration.failed?
          @migration.update!(status: 'pending_plc', last_error: nil, error_code: nil, current_job_attempt: 0)
        end
      end

      redirect_to migration_by_token_path(@migration.token), notice: notice_msg

    rescue StandardError => e
      Rails.logger.error("Re-authentication failed for migration #{@migration.token}: #{e.message}")
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.reauth_error', error: e.message)
    end
  end

  # POST /migrate/:token/request_cancellation
  # Initiates migration cancellation by sending a confirmation email
  def request_cancellation
    unless @migration.cancellable?
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.cannot_cancel')
      return
    end

    # Generate cancellation token and store in progress_data
    cancellation_token = SecureRandom.urlsafe_base64(32)
    @migration.progress_data['cancellation_token'] = cancellation_token
    @migration.progress_data['cancellation_requested_at'] = Time.current.iso8601
    @migration.save!

    # Send confirmation email
    begin
      MigrationMailer.cancellation_confirmation(@migration).deliver_later
      Rails.logger.info("[CancelMigration] Cancellation confirmation email sent for migration #{@migration.token}")
    rescue StandardError => e
      Rails.logger.error("[CancelMigration] Failed to send cancellation email for #{@migration.token}: #{e.message}")
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.cancel_email_failed')
      return
    end

    redirect_to migration_by_token_path(@migration.token),
                notice: I18n.t('controllers.migrations.cancellation_sent')
  end

  # GET /migrate/:token/confirm_cancellation?cancellation_token=XYZ
  # Confirms and executes migration cancellation
  def confirm_cancellation
    stored_token = @migration.progress_data&.dig('cancellation_token')
    provided_token = params[:cancellation_token]

    if stored_token.blank? || provided_token.blank? || stored_token != provided_token
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.invalid_cancel_link')
      return
    end

    unless @migration.cancellable?
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.cancel_too_late')
      return
    end

    # Cancel the migration
    @migration.progress_data.delete('cancellation_token')
    @migration.progress_data.delete('cancellation_requested_at')
    @migration.progress_data['cancelled_at'] = Time.current.iso8601
    @migration.save!
    @migration.mark_failed!("Migration cancelled by user.", error_code: :cancelled)

    Rails.logger.info("[CancelMigration] Migration #{@migration.token} cancelled by user")

    redirect_to migration_by_token_path(@migration.token),
                notice: I18n.t('controllers.migrations.cancelled', pds: @migration.old_pds_host)
  end

  # POST /migrate/:token/confirm_delete
  # Permanently delete a completed migration record at the user's request.
  # This allows users to delete their data immediately after saving their
  # rotation key and backup, instead of waiting for the 2-day auto-deletion.
  def confirm_delete
    unless @migration.completed?
      redirect_to migration_by_token_path(@migration.token),
                  alert: I18n.t('controllers.migrations.only_completed')
      return
    end

    Rails.logger.info("User requested deletion of completed migration #{@migration.token}")

    # Clean up associated files
    @migration.cleanup_backup! if @migration.backup_bundle_path.present?
    @migration.cleanup_downloaded_data! if @migration.downloaded_data_path.present?

    # Delete the migration record
    token = @migration.token
    @migration.destroy!

    Rails.logger.info("Migration #{token} deleted at user request")

    # Redirect to root with a confirmation message
    redirect_to root_path,
                notice: I18n.t('controllers.migrations.deleted', site_name: EuroskyConfig::SITE_NAME)
  rescue StandardError => e
    Rails.logger.error("Failed to delete migration #{@migration&.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: I18n.t('controllers.migrations.unexpected_error')
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
      render plain: I18n.t('controllers.migrations.backup_not_found'), status: :not_found
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
    render plain: I18n.t('controllers.migrations.unexpected_error'), status: :internal_server_error
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
                  alert: I18n.t('controllers.migrations.not_failed')
      return
    end

    # Reset error state and retry from the current status
    @migration.update!(
      status: determine_retry_status(@migration.status),
      last_error: nil,
      error_code: nil,
      current_job_attempt: 0
    )

    # Enqueue the appropriate job based on the status
    enqueue_job_for_status(@migration)

    Rails.logger.info("Migration #{@migration.token} retry requested by user")
    redirect_to migration_by_token_path(@migration.token),
                notice: I18n.t('controllers.migrations.retry_started')
  rescue StandardError => e
    Rails.logger.error("Failed to retry migration #{@migration.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: I18n.t('controllers.migrations.unexpected_error')
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
                  alert: I18n.t('controllers.migrations.no_failed_blobs')
      return
    end

    # Enqueue job to retry just the failed blobs
    RetryFailedBlobsJob.perform_later(@migration.id, failed_blobs)

    Rails.logger.info("Retry failed blobs requested for migration #{@migration.token} (#{failed_blobs.length} blobs)")
    redirect_to migration_by_token_path(@migration.token),
                notice: I18n.t('controllers.migrations.retrying_blobs', count: failed_blobs.length)
  rescue StandardError => e
    Rails.logger.error("Failed to retry failed blobs for migration #{@migration.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: I18n.t('controllers.migrations.unexpected_error')
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
        render json: { error: I18n.t('controllers.migrations.migration_not_found') }, status: :not_found
      else
        render plain: "#{I18n.t('controllers.migrations.migration_not_found')}: #{token}", status: :not_found
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
    allowed << :target_pds_contact_email
    allowed << :invite_code if EuroskyConfig.invite_code_enabled?
    # Note: legal_consent is intentionally excluded — it's not a model attribute.
    # It's checked directly via params[:migration][:legal_consent] in the create action.

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
      blobs_total: blob_data[:total],
      blobs_completed: blob_data[:completed],
      bytes_transferred: blob_data[:bytes_transferred],
      bytes_transferred_formatted: helpers.number_to_human_size(blob_data[:bytes_transferred]),
      blobs_failed: blob_data[:failed],
      last_error: @migration.last_error,
      completed: @migration.completed?,
      failed: @migration.failed?,
      email_verified: @migration.email_verified?,
      job_retrying: @migration.job_retrying?,
      current_job_step: @migration.current_job_step,
      current_job_attempt: @migration.current_job_attempt,
      current_job_max_attempts: @migration.current_job_max_attempts,
      queued: @migration.progress_data&.dig('queued') || false,
      queued_reason: @migration.progress_data&.dig('queued_reason'),
      created_at: @migration.created_at.iso8601,
      updated_at: @migration.updated_at.iso8601
    }
  end

  # Calculate blob upload statistics from progress_data
  # Uses aggregate counters from ImportBlobsJob (blobs_completed/blobs_total/bytes_transferred)
  def calculate_blob_statistics
    {
      total: @migration.progress_data['blobs_total'].to_i,
      completed: @migration.progress_data['blobs_completed'].to_i,
      bytes_transferred: @migration.progress_data['bytes_transferred'].to_i,
      failed: (@migration.progress_data['failed_blobs'] || []).length
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

  # Verify hCaptcha response token against hCaptcha's API
  # Fetch the hCaptcha site key from the gatekeeper's signup page HTML.
  # The site key is embedded in a data-sitekey attribute on the captcha div.
  def fetch_captcha_site_key(pds_host)
    gate_url = "#{pds_host}/gate/signup?handle=probe&state=probe"
    response = HTTParty.get(gate_url, timeout: 10)
    return nil unless response.success?

    match = response.body.match(/data-sitekey="([^"]+)"/)
    match&.captures&.first
  rescue StandardError => e
    Rails.logger.warn("Failed to fetch captcha site key from #{pds_host}: #{e.message}")
    nil
  end

  # Exchange an hCaptcha response token for a gate code from pds-gatekeeper.
  # Posts to the gatekeeper's /gate/signup endpoint which validates the captcha,
  # generates a JWE gate code, stores it in the PDS database, and returns a
  # redirect with ?code=GATE_CODE. We extract that code for createAccount.
  def exchange_captcha_for_gate_code(captcha_response, migration)
    gate_url = "#{migration.new_pds_host}/gate/signup?handle=#{CGI.escape(migration.new_handle)}&state=migration"

    Rails.logger.info("Exchanging hCaptcha token for gate code at #{gate_url}")

    # POST with form-encoded body (gatekeeper expects form data, not JSON)
    # follow_redirects: false so we can extract the code from the Location header
    result = HTTParty.post(
      gate_url,
      body: {
        'h-captcha-response' => captcha_response,
        'redirect_url' => "#{migration.new_pds_host}"
      },
      follow_redirects: false,
      timeout: 15
    )

    if result.code == 302 || result.code == 303
      location = result.headers['location']
      uri = URI.parse(location)
      code = CGI.parse(uri.query || '')['code']&.first

      if code.present?
        Rails.logger.info("Gate code obtained for handle #{migration.new_handle}")
        return code
      else
        Rails.logger.warn("Gate redirect had no code param: #{location}")
        return nil
      end
    else
      Rails.logger.warn("Gate code exchange failed (HTTP #{result.code}): #{result.body}")
      return nil
    end
  rescue StandardError => e
    Rails.logger.error("Gate code exchange error: #{e.message}")
    nil
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

  # Check if a PDS host is Eurosky's own PDS
  # Only records PdsConsent for Eurosky migrations to avoid Eurosky becoming
  # a data controller for third-party PDS compliance data
  def is_eurosky_pds?(pds_host)
    return false if pds_host.blank?

    normalized = normalize_pds_host(pds_host)

    # In bound mode, only the pre-configured PDS is Eurosky
    if EuroskyConfig.bound_mode?
      normalized_target = normalize_pds_host(EuroskyConfig::TARGET_PDS_HOST)
      return normalized == normalized_target
    end

    # In standalone mode, only record if there's a configured default Eurosky PDS
    # This is optional — if not set, no PdsConsent records are created (conservative approach)
    if EuroskyConfig::DEFAULT_TARGET_PDS.present?
      normalized_default = normalize_pds_host(EuroskyConfig::DEFAULT_TARGET_PDS)
      return normalized == normalized_default
    end

    # Default: don't record for unknown PDS (safer for GDPR compliance)
    false
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
    pds_host = "https://#{pds_host}" unless pds_host.start_with?('http://', 'https://')
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
  def authenticate_and_fetch_profile(pds_host, identifier, password, auth_factor_token: nil)
    # Create session to authenticate
    session_url = "#{pds_host}/xrpc/com.atproto.server.createSession"

    body = {
      identifier: identifier,
      password: password
    }
    body[:authFactorToken] = auth_factor_token if auth_factor_token.present?

    response = HTTParty.post(
      session_url,
      headers: { 'Content-Type' => 'application/json' },
      body: body.to_json,
      timeout: 30
    )

    unless response.success?
      error_body = JSON.parse(response.body) rescue {}

      # Check for 2FA requirement
      if error_body['error'] == 'AuthFactorTokenRequired'
        raise GoatService::TwoFactorRequiredError, "Two-factor authentication is required. Check your email for a sign-in code."
      end

      error_message = error_body['message'] || error_body['error'] || 'Authentication failed'
      raise AuthenticationError, error_message
    end

    session_data = JSON.parse(response.body)

    # Decode the JWT payload to check auth scope — app passwords lack
    # the privileges needed to request service auth tokens for createAccount.
    jwt_payload = JSON.parse(Base64.urlsafe_decode64(session_data['accessJwt'].split('.')[1]))
    scope = jwt_payload['scope']

    if scope != 'com.atproto.access'
      raise AuthenticationError, I18n.t('controllers.migrations.app_password_not_allowed')
    end

    email = session_data['email']
    handle = session_data['handle']

    Rails.logger.info("Successfully authenticated #{identifier}, email: #{email.present? ? 'present' : 'not available'}, scope: #{scope}")

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
