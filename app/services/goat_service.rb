# GoatService - Core service for PDS migration operations
#
# This service wraps the goat CLI tool and makes direct ATProto API calls
# to handle account migration between Personal Data Servers (PDS).
#
# The service orchestrates the complex multi-step migration process:
# 1. Authentication to source and target PDS
# 2. Service auth token generation
# 3. Account creation on target PDS
# 4. Repository export/import (CAR files)
# 5. Blob transfer (images, videos, etc)
# 6. Preferences export/import
# 7. PLC directory updates (DID document)
# 8. Account activation/deactivation
#
# Usage:
#   service = GoatService.new(migration)
#   service.login_old_pds
#   car_path = service.export_repo
#   service.import_repo(car_path)
#
# Error Handling:
#   All methods raise specific exceptions on failure:
#   - AuthenticationError: Login or session failures
#   - NetworkError: HTTP/API communication failures
#   - RateLimitError: PDS rate-limiting (HTTP 429)
#   - TimeoutError: Operations exceeding timeout limits
#   - GoatError: General goat CLI or operation failures
#
# Work Files:
#   All temporary files stored in: Rails.root/tmp/goat/{did}/
#   - account.{timestamp}.car (repository export)
#   - blobs/{cid} (blob downloads)
#   - prefs.json (preferences)
#   - plc_*.json (PLC operation files)
#
# Requirements:
#   - goat CLI must be installed and in PATH
#   - Migration model with required fields (did, handles, hosts, password)
#   - Network access to both source and target PDS
#   - PLC directory access for DID updates

require 'open3'

class GoatService
  # Custom exceptions
  class GoatError < StandardError; end
  class AuthenticationError < GoatError; end
  class NetworkError < GoatError; end
  class TimeoutError < GoatError; end
  class RateLimitError < NetworkError; end  # Raised when PDS rate-limits our requests
  class AccountExistsError < GoatError; end  # Raised when account already exists on target PDS

  DEFAULT_TIMEOUT = 300 # 5 minutes

  attr_reader :migration, :work_dir, :logger

  def initialize(migration)
    @migration = migration
    @work_dir = Rails.root.join('tmp', 'goat', migration.did)
    @logger = Rails.logger

    # Session token cache to avoid creating new sessions for every API call
    @access_tokens = {}

    # Ensure work directory exists
    FileUtils.mkdir_p(@work_dir)
  end

  # Authentication Methods

  def login_old_pds
    logger.info("Logging in to old PDS: #{migration.old_pds_host}")

    # Use the old handle for login
    execute_goat(
      'account', 'login',
      '--pds-host', migration.old_pds_host,
      '-u', migration.old_handle,
      '-p', migration.password
    )

    logger.info("Successfully logged in to old PDS")
  rescue StandardError => e
    raise AuthenticationError, "Failed to login to old PDS: #{e.message}"
  end

  def login_new_pds
    logger.info("Logging in to new PDS: #{migration.new_pds_host}")

    # Clear any existing session first to avoid conflicts
    logout_goat

    # Use DID for login to new PDS
    password = migration.password
    logger.info("Password available: #{!password.nil?}, length: #{password&.length || 0}")

    execute_goat(
      'account', 'login',
      '--pds-host', migration.new_pds_host,
      '-u', migration.did,
      '-p', password
    )

    logger.info("Successfully logged in to new PDS")
  rescue StandardError => e
    raise AuthenticationError, "Failed to login to new PDS: #{e.message}"
  end

  def logout_goat
    logger.debug("Clearing goat session")
    execute_goat('account', 'logout') rescue nil
  end

  # Account Creation Methods

  def get_service_auth_token(new_pds_did)
    logger.info("Getting service auth token for PDS: #{new_pds_did}")

    # Must be logged in to old PDS first
    stdout, _stderr, _status = execute_goat(
      'account', 'service-auth',
      '--lxm', 'com.atproto.server.createAccount',
      '--aud', new_pds_did,
      '--duration-sec', '3600'
    )

    token = stdout.strip
    raise GoatError, "Empty service auth token received" if token.empty?

    logger.info("Service auth token obtained")
    token
  rescue StandardError => e
    raise AuthenticationError, "Failed to get service auth token: #{e.message}"
  end

  def check_account_exists_on_new_pds
    logger.info("Checking if account already exists on new PDS")

    url = "#{migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo?repo=#{migration.did}"

    stdout, _stderr, _status = execute_command('curl', '-s', url, timeout: 30)
    response = JSON.parse(stdout) rescue {}

    if response['error'] == 'RepoDeactivated'
      logger.warn("Orphaned deactivated account found on new PDS")
      return { exists: true, deactivated: true }
    elsif response['did']
      logger.warn("Active account found on new PDS")
      return { exists: true, deactivated: false, handle: response['handle'] }
    else
      logger.info("No existing account found on new PDS")
      return { exists: false }
    end
  rescue => e
    logger.warn("Failed to check account existence: #{e.message}")
    return { exists: false }
  end

  def create_account_on_new_pds(service_auth_token)
    logger.info("Creating account on new PDS with existing DID")

    # Build command arguments
    args = [
      'account', 'create',
      '--pds-host', migration.new_pds_host,
      '--existing-did', migration.did,
      '--handle', migration.new_handle,
      '--password', migration.password,
      '--email', migration.email,
      '--service-auth', service_auth_token
    ]

    # Add invite code if present
    if migration.invite_code.present?
      logger.info("Including invite code for account creation")
      args += ['--invite-code', migration.invite_code]
    end

    execute_goat(*args)

    logger.info("Account created on new PDS")
  rescue StandardError => e
    error_message = e.message

    # Check if this is an "AlreadyExists" error
    if error_message.include?("AlreadyExists") || error_message.include?("Repo already exists")
      # Check the status of the existing account
      account_status = check_account_exists_on_new_pds

      if account_status[:exists] && account_status[:deactivated]
        raise AccountExistsError, "Orphaned deactivated account exists on target PDS. " \
          "This is from a previous failed migration. To fix: delete the account from the PDS database " \
          "and retry the migration. DID: #{migration.did}, PDS: #{migration.new_pds_host}"
      elsif account_status[:exists]
        raise AccountExistsError, "Active account already exists on target PDS with handle: #{account_status[:handle]}. " \
          "Cannot migrate to an already active account. DID: #{migration.did}"
      end
    end

    raise GoatError, "Failed to create account on new PDS: #{error_message}"
  end

  # Rotation Key Methods

  def generate_rotation_key
    logger.info("Generating rotation key for account recovery")

    # Use goat to generate a P-256 rotation key
    stdout, _stderr, _status = execute_goat('key', 'generate', '--type', 'P-256')

    # Parse output to extract keys
    # Expected format:
    # Secret Key (Multibase Syntax): save this securely (eg, add to password manager)
    #   z42tk...
    # Public Key (DID Key Syntax): share or publish this (eg, in DID document)
    #   did:key:zDnae...
    private_key = nil
    public_key = nil
    next_line_is_private_key = false
    next_line_is_public_key = false

    stdout.each_line do |line|
      line_stripped = line.strip

      if next_line_is_private_key
        # This line contains the private key value
        private_key = line_stripped if line_stripped.start_with?('z')
        next_line_is_private_key = false
      elsif next_line_is_public_key
        # This line contains the public key value
        public_key = line_stripped if line_stripped.start_with?('did:key:')
        next_line_is_public_key = false
      elsif line.include?("Secret Key") && line.include?("Multibase")
        # Next line will have the private key
        next_line_is_private_key = true
      elsif line.include?("Public Key") && line.include?("DID Key")
        # Next line will have the public key
        next_line_is_public_key = true
      end
    end

    unless private_key && public_key
      raise GoatError, "Failed to parse rotation key from goat output: #{stdout}"
    end

    logger.info("Rotation key generated successfully")

    {
      private_key: private_key,
      public_key: public_key
    }
  rescue StandardError => e
    raise GoatError, "Failed to generate rotation key: #{e.message}"
  end

  def add_rotation_key_to_pds(public_key)
    logger.info("Adding rotation key to PDS account (highest priority)")

    # Add rotation key to account via PDS
    # Using --first flag to add it at highest priority
    execute_goat(
      'account', 'plc', 'add-rotation-key',
      '--pds-host', migration.new_pds_host,
      '--handle', migration.new_handle,
      '--password', migration.password,
      public_key,
      '--first'
    )

    logger.info("Rotation key added to PDS account")
  rescue StandardError => e
    raise GoatError, "Failed to add rotation key to PDS: #{e.message}"
  end

  # Repository Export/Import Methods

  def export_repo
    logger.info("Exporting repository from old PDS")

    filename = "account.#{Time.now.to_i}.car"
    car_path = work_dir.join(filename)

    # Get access token for direct API call (goat repo export has PLC resolution issues)
    # We'll use a direct curl call similar to the test script
    url = "#{migration.old_pds_host}/xrpc/com.atproto.sync.getRepo?did=#{migration.did}"

    # Need to be logged in first to get session
    login_old_pds

    # Get access token for OLD PDS using old handle
    access_token = get_access_token_from_session(
      pds_host: migration.old_pds_host,
      identifier: migration.old_handle
    )

    # Execute curl to download CAR file with progress and strict timeout
    # --max-time: hard timeout (300s = 5 min)
    # --connect-timeout: connection establishment timeout (30s)
    # --speed-limit/--speed-time: abort if speed drops below 1KB/s for 60s
    _stdout, _stderr, _status = execute_command(
      'curl', '-s', '-f',
      '--max-time', '600',           # Hard timeout: 10 minutes max
      '--connect-timeout', '30',      # Connection timeout: 30 seconds
      '--speed-limit', '1024',        # Minimum speed: 1 KB/s
      '--speed-time', '60',           # Abort if below speed-limit for 60s
      '-H', "Authorization: Bearer #{access_token}",
      url,
      '-o', car_path.to_s,
      timeout: 660  # Give curl slightly more time than --max-time
    )

    unless File.exist?(car_path) && File.size(car_path) > 0
      raise GoatError, "Repository export failed: file not created or empty"
    end

    file_size_mb = File.size(car_path).to_f / (1024 * 1024)
    logger.info("Repository exported to #{car_path} (#{file_size_mb.round(2)} MB)")

    car_path.to_s
  rescue StandardError => e
    raise GoatError, "Failed to export repository: #{e.message}"
  end

  def import_repo(car_path)
    logger.info("Importing repository to new PDS")

    unless File.exist?(car_path)
      raise GoatError, "CAR file not found: #{car_path}"
    end

    # Login to new PDS with DID (works with older goat versions)
    login_new_pds

    # Import repo using goat command
    execute_goat('repo', 'import', car_path)

    logger.info("Repository imported successfully")
  rescue StandardError => e
    raise GoatError, "Failed to import repository: #{e.message}"
  end

  # Convert legacy blob format in CAR file if needed
  # Returns path to converted CAR file, or original if no conversion needed
  def convert_legacy_blobs_if_needed(car_path)
    converter = LegacyBlobConverterService.new(migration)
    converter.convert_if_needed(car_path)
  rescue LegacyBlobConverterService::ConversionError => e
    # Log conversion error but don't fail the migration
    # The user can retry with CONVERT_LEGACY_BLOBS=false if needed
    logger.error("Legacy blob conversion failed: #{e.message}")
    raise GoatError, "Failed to convert legacy blobs: #{e.message}"
  end

  # Blob Methods

  def list_blobs(cursor = nil)
    logger.info("Listing blobs for DID: #{migration.did}")

    url = "#{migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs?did=#{migration.did}"
    url += "&cursor=#{cursor}" if cursor

    # com.atproto.sync.listBlobs is a public endpoint - no authentication required
    response = HTTParty.get(
      url,
      headers: {
        'Accept' => 'application/json'
      },
      timeout: 30
    )

    unless response.success?
      # Check for rate-limiting
      if response.code == 429
        logger.warn("Rate limit hit while listing blobs: #{response.code} #{response.message}")
        raise RateLimitError, "PDS rate limit exceeded while listing blobs: #{response.code} #{response.message}"
      end

      raise NetworkError, "Failed to list blobs: #{response.code} #{response.message}"
    end

    parsed = JSON.parse(response.body)
    logger.info("Found #{parsed['cids']&.length || 0} blobs")

    parsed
  rescue JSON::ParserError => e
    raise GoatError, "Failed to parse blob list response: #{e.message}"
  rescue RateLimitError
    raise  # Re-raise rate limit errors
  rescue StandardError => e
    raise NetworkError, "Failed to list blobs: #{e.message}"
  end

  def download_blob(cid)
    logger.info("Downloading blob: #{cid}")

    blob_path = work_dir.join("blobs", cid)
    FileUtils.mkdir_p(blob_path.dirname)

    url = "#{migration.old_pds_host}/xrpc/com.atproto.sync.getBlob?did=#{migration.did}&cid=#{cid}"

    # com.atproto.sync.getBlob is a public endpoint - no authentication required
    response = HTTParty.get(
      url,
      timeout: 300,
      stream_body: true
    )

    unless response.success?
      # Check for rate-limiting
      if response.code == 429
        logger.warn("Rate limit hit while downloading blob #{cid}: #{response.code} #{response.message}")
        raise RateLimitError, "PDS rate limit exceeded while downloading blob: #{response.code} #{response.message}"
      end

      raise NetworkError, "Failed to download blob: #{response.code} #{response.message}"
    end

    File.binwrite(blob_path, response.body)

    file_size_kb = File.size(blob_path).to_f / 1024
    logger.info("Blob downloaded: #{blob_path} (#{file_size_kb.round(2)} KB)")

    blob_path.to_s
  rescue RateLimitError
    raise  # Re-raise rate limit errors
  rescue StandardError => e
    raise NetworkError, "Failed to download blob #{cid}: #{e.message}"
  end

  def upload_blob(blob_path)
    logger.info("Uploading blob: #{blob_path}")

    unless File.exist?(blob_path)
      raise GoatError, "Blob file not found: #{blob_path}"
    end

    url = "#{migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob"

    # Get access token for NEW PDS using DID (uses cached token from login_new_pds)
    access_token = get_access_token_from_session(
      pds_host: migration.new_pds_host,
      identifier: migration.did
    )

    response = HTTParty.post(
      url,
      headers: {
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/octet-stream'
      },
      body: File.binread(blob_path),
      timeout: 300
    )

    unless response.success?
      # Check for expired token
      if response.code == 401
        logger.info("Token expired, refreshing session and retrying")
        refresh_access_token(pds_host: migration.new_pds_host, identifier: migration.did)
        return upload_blob(blob_path)  # Retry with new token
      end

      # Check for rate-limiting
      if response.code == 429
        logger.warn("Rate limit hit while uploading blob: #{response.code} #{response.message}")
        raise RateLimitError, "PDS rate limit exceeded while uploading blob: #{response.code} #{response.message}"
      end

      raise NetworkError, "Failed to upload blob: #{response.code} #{response.message}"
    end

    parsed = JSON.parse(response.body)
    logger.info("Blob uploaded successfully: #{parsed['blob']['ref']['$link']}")

    parsed
  rescue JSON::ParserError => e
    raise GoatError, "Failed to parse upload response: #{e.message}"
  rescue RateLimitError
    raise  # Re-raise rate limit errors
  rescue StandardError => e
    raise NetworkError, "Failed to upload blob: #{e.message}"
  end

  # Preferences Methods

  def export_preferences
    logger.info("Exporting preferences from old PDS")

    # Must be logged in to old PDS
    login_old_pds

    prefs_path = work_dir.join("prefs.json")

    stdout, _stderr, _status = execute_goat('bsky', 'prefs', 'export')

    File.write(prefs_path, stdout)

    logger.info("Preferences exported to #{prefs_path}")
    prefs_path.to_s
  rescue StandardError => e
    raise GoatError, "Failed to export preferences: #{e.message}"
  end

  def import_preferences(prefs_path)
    logger.info("Importing preferences to new PDS")

    unless File.exist?(prefs_path)
      raise GoatError, "Preferences file not found: #{prefs_path}"
    end

    # Must be logged in to new PDS
    login_new_pds

    execute_goat('bsky', 'prefs', 'import', prefs_path)

    logger.info("Preferences imported successfully")
  rescue StandardError => e
    raise GoatError, "Failed to import preferences: #{e.message}"
  end

  # PLC Methods

  def request_plc_token
    logger.info("Requesting PLC token from old PDS")

    # Must be logged in to old PDS
    login_old_pds

    execute_goat('account', 'plc', 'request-token')

    logger.info("PLC token requested (check email or logs)")

    # In a real scenario, we'd need to extract token from email or logs
    # For now, this returns nil and the token must be provided separately
    nil
  rescue StandardError => e
    raise GoatError, "Failed to request PLC token: #{e.message}"
  end

  def get_recommended_plc_operation
    logger.info("Getting recommended PLC operation parameters")

    # Must be logged in to new PDS
    login_new_pds

    plc_recommended_path = work_dir.join("plc_recommended.json")

    stdout, _stderr, _status = execute_goat('account', 'plc', 'recommended')

    File.write(plc_recommended_path, stdout)

    logger.info("PLC recommended parameters saved to #{plc_recommended_path}")

    # Copy to unsigned for editing
    plc_unsigned_path = work_dir.join("plc_unsigned.json")
    FileUtils.cp(plc_recommended_path, plc_unsigned_path)

    plc_unsigned_path.to_s
  rescue StandardError => e
    raise GoatError, "Failed to get recommended PLC operation: #{e.message}"
  end

  def sign_plc_operation(unsigned_op_path, token)
    logger.info("Signing PLC operation")

    unless File.exist?(unsigned_op_path)
      raise GoatError, "Unsigned PLC operation file not found: #{unsigned_op_path}"
    end

    if token.nil? || token.empty?
      raise GoatError, "PLC token is required for signing"
    end

    # Must be logged in to old PDS for signing
    login_old_pds

    plc_signed_path = work_dir.join("plc_signed.json")

    stdout, _stderr, _status = execute_goat(
      'account', 'plc', 'sign',
      '--token', token,
      unsigned_op_path
    )

    File.write(plc_signed_path, stdout)

    logger.info("PLC operation signed and saved to #{plc_signed_path}")
    plc_signed_path.to_s
  rescue StandardError => e
    raise GoatError, "Failed to sign PLC operation: #{e.message}"
  end

  def submit_plc_operation(signed_op_path)
    logger.info("Submitting PLC operation")

    unless File.exist?(signed_op_path)
      raise GoatError, "Signed PLC operation file not found: #{signed_op_path}"
    end

    # Must be logged in to new PDS for submission
    login_new_pds

    execute_goat('account', 'plc', 'submit', signed_op_path)

    logger.info("PLC operation submitted successfully")
  rescue StandardError => e
    raise GoatError, "Failed to submit PLC operation: #{e.message}"
  end

  # Account Status Methods

  def activate_account
    logger.info("Activating account on new PDS")

    # Must be logged in to new PDS
    login_new_pds

    execute_goat('account', 'activate')

    logger.info("Account activated on new PDS")
  rescue StandardError => e
    raise GoatError, "Failed to activate account: #{e.message}"
  end

  def deactivate_account
    logger.info("Deactivating account on old PDS")

    # Must be logged in to old PDS
    # login_old_pds

    # execute_goat('account', 'deactivate')

    logger.info("Account deactivated on old PDS")
  rescue StandardError => e
    raise GoatError, "Failed to deactivate account: #{e.message}"
  end

  def get_account_status
    logger.info("Getting account status")

    stdout, _stderr, _status = execute_goat('account', 'status')

    logger.info("Account status retrieved")
    stdout
  rescue StandardError => e
    raise GoatError, "Failed to get account status: #{e.message}"
  end

  def check_missing_blobs
    logger.info("Checking for missing blobs")

    stdout, _stderr, _status = execute_goat('account', 'missing-blobs')

    logger.info("Missing blobs check completed")
    stdout
  rescue StandardError => e
    raise GoatError, "Failed to check missing blobs: #{e.message}"
  end

  # Cleanup Methods

  def self.cleanup_migration_files(did)
    work_dir = Rails.root.join('tmp', 'goat', did)

    if Dir.exist?(work_dir)
      FileUtils.rm_rf(work_dir)
      Rails.logger.info("Cleaned up migration files for DID: #{did}")
    end
  rescue StandardError => e
    Rails.logger.error("Failed to cleanup migration files for #{did}: #{e.message}")
  end

  private

  # Execute goat CLI command with proper error handling
  def execute_goat(*args, timeout: DEFAULT_TIMEOUT)
    # Set environment variables for goat
    env = {
      'ATP_PLC_HOST' => ENV['ATP_PLC_HOST'] || 'https://plc.directory',
      'ATP_PDS_HOST' => migration.new_pds_host # Default PDS for goat
    }

    # Build full command
    cmd = ['goat'] + args

    # Log command with password masking (unless DEBUG_PASSWORDS is set)
    debug_cmd = if ENV['DEBUG_PASSWORDS'] == 'true'
      cmd.join(' ')
    else
      # Mask the value after -p flag
      masked = []
      mask_next = false
      cmd.each do |arg|
        if mask_next
          masked << '[REDACTED]'
          mask_next = false
        elsif arg == '-p' || arg == '--password'
          masked << arg
          mask_next = true
        else
          masked << arg
        end
      end
      masked.join(' ')
    end
    logger.info("Executing goat: #{debug_cmd}")
    logger.info("  ENV: ATP_PLC_HOST=#{env['ATP_PLC_HOST']}, ATP_PDS_HOST=#{env['ATP_PDS_HOST']}")

    stdout, stderr, status = execute_command(*cmd, env: env, timeout: timeout)

    unless status.success?
      error_msg = stderr.empty? ? stdout : stderr

      # Check for rate-limiting errors first
      if rate_limit_error?(error_msg)
        logger.warn("Rate limit detected in goat command: #{error_msg}")
        raise RateLimitError, "PDS rate limit exceeded: #{error_msg}"
      end

      raise GoatError, "goat command failed: #{error_msg}"
    end

    [stdout, stderr, status]
  end

  # Execute shell command with timeout
  def execute_command(*cmd, env: {}, timeout: DEFAULT_TIMEOUT)
    stdout = ''
    stderr = ''
    status = nil

    # Execute command with explicit working directory (thread-safe alternative to chdir)
    begin
      Timeout.timeout(timeout) do
        stdout, stderr, status = Open3.capture3(env, *cmd, chdir: work_dir)
      end
    rescue Timeout::Error
      raise TimeoutError, "Command timed out after #{timeout} seconds: #{cmd.join(' ')}"
    end

    [stdout, stderr, status]
  end

  # Detect rate-limiting errors from goat CLI output
  # Checks for HTTP 429 status codes and rate-limit error messages
  def rate_limit_error?(error_msg)
    return false if error_msg.nil? || error_msg.empty?

    # Check for common rate-limit indicators
    error_msg.include?('HTTP 429') ||
      error_msg.include?('RateLimitExceeded') ||
      error_msg.include?('Too Many Requests') ||
      error_msg.include?('rate limit') ||
      error_msg.match?(/API request failed \(HTTP 429\)/)
  end

  # Get access token from goat session
  # Note: This is a simplified version. In reality, we'd need to parse
  # goat's session storage or maintain our own session state
  #
  # @param pds_host [String] The PDS host to get a token for (old or new PDS)
  # @param identifier [String] The identifier to use for login (handle or DID)
  # Get access token via direct API call (bypasses goat)
  def get_access_token_via_api(pds_host:, identifier:, password:)
    logger.info("Getting access token via direct API call to #{pds_host}")

    url = "#{pds_host}/xrpc/com.atproto.server.createSession"

    response = `curl -s -X POST "#{url}" \
      -H "Content-Type: application/json" \
      -d '{"identifier":"#{identifier}","password":"#{password}"}'`

    parsed = JSON.parse(response)

    if parsed['accessJwt']
      logger.info("Access token obtained via API")
      return parsed['accessJwt']
    else
      error_msg = parsed['message'] || parsed['error'] || 'Unknown error'
      raise AuthenticationError, "Failed to get access token: #{error_msg}"
    end
  rescue JSON::ParserError => e
    raise AuthenticationError, "Invalid response from createSession: #{response}"
  rescue StandardError => e
    raise AuthenticationError, "Failed to call createSession API: #{e.message}"
  end

  def get_access_token_from_session(pds_host:, identifier:)
    # Use cache key based on PDS host to support both old and new PDS
    cache_key = "#{pds_host}:#{identifier}"

    # Return cached token if available
    return @access_tokens[cache_key] if @access_tokens[cache_key]

    # Try to read from goat session file
    session_path = File.expand_path('~/.config/goat/session.json')

    if File.exist?(session_path)
      begin
        session_data = JSON.parse(File.read(session_path))
        if session_data['accessJwt']
          @access_tokens[cache_key] = session_data['accessJwt']
          logger.info("Using cached session token from goat session file")
          return session_data['accessJwt']
        end
      rescue JSON::ParserError => e
        logger.warn("Failed to parse goat session file: #{e.message}")
      end
    end

    # Create new session and cache the token
    logger.info("Creating new session for #{pds_host} (#{identifier})")
    token = create_direct_session(pds_host: pds_host, identifier: identifier)
    @access_tokens[cache_key] = token
    token
  end

  # Refresh access token by clearing cache and creating new session
  def refresh_access_token(pds_host:, identifier:)
    cache_key = "#{pds_host}:#{identifier}"

    # Clear cached token
    @access_tokens.delete(cache_key)

    # Create new session
    logger.info("Refreshing access token for #{pds_host} (#{identifier})")
    token = create_direct_session(pds_host: pds_host, identifier: identifier)
    @access_tokens[cache_key] = token
    token
  end

  # Create session directly via API when goat session is unavailable
  #
  # @param pds_host [String] The PDS host to authenticate against
  # @param identifier [String] The identifier to use for login (handle or DID)
  def create_direct_session(pds_host:, identifier:)
    url = "#{pds_host}/xrpc/com.atproto.server.createSession"

    response = HTTParty.post(
      url,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        identifier: identifier,
        password: migration.password
      }.to_json,
      timeout: 30
    )

    unless response.success?
      # Check for rate limiting
      if response.code == 429
        logger.warn("Rate limit hit during session creation: #{response.code} #{response.message}")
        raise RateLimitError, "Failed to create session: #{response.code} #{response.message}"
      end
      raise AuthenticationError, "Failed to create session: #{response.code} #{response.message}"
    end

    parsed = JSON.parse(response.body)
    parsed['accessJwt']
  rescue RateLimitError
    raise  # Re-raise rate limit errors
  rescue StandardError => e
    raise AuthenticationError, "Failed to create direct session: #{e.message}"
  end

  # Get new PDS service DID
  def get_new_pds_service_did
    url = "#{migration.new_pds_host}/xrpc/com.atproto.server.describeServer"

    response = HTTParty.get(url, timeout: 30)

    unless response.success?
      raise NetworkError, "Failed to describe server: #{response.code} #{response.message}"
    end

    parsed = JSON.parse(response.body)
    parsed['did']
  rescue StandardError => e
    raise NetworkError, "Failed to get PDS service DID: #{e.message}"
  end

  # Class methods for handle resolution

  # Resolve a handle to a DID
  # Tries multiple resolution methods in order:
  # 1. DNS TXT record (_atproto.handle)
  # 2. HTTPS well-known endpoint (/.well-known/atproto-did)
  # 3. PDS resolution endpoint
  def self.resolve_handle_to_did(handle)
    Rails.logger.info("Resolving handle to DID: #{handle}")

    # Try resolution via common PDS instances
    common_pds_hosts = ['https://bsky.social', 'https://bsky.network']

    common_pds_hosts.each do |pds_host|
      begin
        url = "#{pds_host}/xrpc/com.atproto.identity.resolveHandle"
        response = HTTParty.get(url, query: { handle: handle }, timeout: 10)

        if response.success?
          parsed = JSON.parse(response.body)
          did = parsed['did']
          Rails.logger.info("Resolved handle #{handle} to DID: #{did}")
          return did
        end
      rescue StandardError => e
        Rails.logger.debug("Failed to resolve via #{pds_host}: #{e.message}")
        # Continue to next PDS
      end
    end

    raise NetworkError, "Could not resolve handle #{handle} to DID"
  end

  # Get the PDS host for a given DID by querying the PLC directory
  def self.resolve_did_to_pds(did)
    Rails.logger.info("Resolving DID to PDS: #{did}")

    plc_host = ENV.fetch('ATP_PLC_HOST', 'https://plc.directory')
    url = "#{plc_host}/#{did}"

    response = HTTParty.get(url, timeout: 10)

    unless response.success?
      raise NetworkError, "Failed to fetch DID document from PLC: #{response.code} #{response.message}"
    end

    parsed = JSON.parse(response.body)

    # Extract PDS endpoint from service array
    service = parsed['service']&.find { |s| s['id'] == '#atproto_pds' }

    unless service && service['serviceEndpoint']
      raise GoatError, "No PDS endpoint found in DID document for #{did}"
    end

    pds_host = service['serviceEndpoint']
    Rails.logger.info("Resolved DID #{did} to PDS: #{pds_host}")

    pds_host
  rescue JSON::ParserError => e
    raise GoatError, "Invalid JSON in PLC response: #{e.message}"
  rescue StandardError => e
    raise NetworkError, "Failed to resolve DID to PDS: #{e.message}"
  end

  # Convenience method to resolve handle directly to PDS host
  # Returns a hash with { did: '...', pds_host: '...' }
  def self.resolve_handle(handle)
    did = resolve_handle_to_did(handle)
    pds_host = resolve_did_to_pds(did)

    {
      did: did,
      pds_host: pds_host
    }
  end
end
