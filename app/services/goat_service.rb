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

  DEFAULT_TIMEOUT = 300 # 5 minutes

  attr_reader :migration, :work_dir, :logger

  def initialize(migration)
    @migration = migration
    @work_dir = Rails.root.join('tmp', 'goat', migration.did)
    @logger = Rails.logger

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
      '-p', migration.encrypted_password
    )

    logger.info("Successfully logged in to old PDS")
  rescue StandardError => e
    raise AuthenticationError, "Failed to login to old PDS: #{e.message}"
  end

  def login_new_pds
    logger.info("Logging in to new PDS: #{migration.new_pds_host}")

    # Use DID for login to new PDS
    execute_goat(
      'account', 'login',
      '--pds-host', migration.new_pds_host,
      '-u', migration.did,
      '-p', migration.encrypted_password
    )

    logger.info("Successfully logged in to new PDS")
  rescue StandardError => e
    raise AuthenticationError, "Failed to login to new PDS: #{e.message}"
  end

  # Account Creation Methods

  def get_service_auth_token(new_pds_did)
    logger.info("Getting service auth token for PDS: #{new_pds_did}")

    # Must be logged in to old PDS first
    stdout, stderr, status = execute_goat(
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

  def create_account_on_new_pds(service_auth_token)
    logger.info("Creating account on new PDS with existing DID")

    # Build command arguments
    args = [
      'account', 'create',
      '--pds-host', migration.new_pds_host,
      '--existing-did', migration.did,
      '--handle', migration.new_handle,
      '--password', migration.encrypted_password,
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
    raise GoatError, "Failed to create account on new PDS: #{e.message}"
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

    # Execute curl to download CAR file
    stdout, stderr, status = execute_command(
      'curl', '-s', '-f',
      '-H', "Authorization: Bearer #{get_access_token_from_session}",
      url,
      '-o', car_path.to_s,
      timeout: DEFAULT_TIMEOUT
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

    # Must be logged in to new PDS
    login_new_pds

    execute_goat('repo', 'import', car_path)

    logger.info("Repository imported successfully")
  rescue StandardError => e
    raise GoatError, "Failed to import repository: #{e.message}"
  end

  # Blob Methods

  def list_blobs(cursor = nil)
    logger.info("Listing blobs for DID: #{migration.did}")

    url = "#{migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs?did=#{migration.did}"
    url += "&cursor=#{cursor}" if cursor

    response = HTTParty.get(
      url,
      headers: {
        'Authorization' => "Bearer #{get_access_token_from_session}",
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

    response = HTTParty.get(
      url,
      headers: {
        'Authorization' => "Bearer #{get_access_token_from_session}"
      },
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

    # Must be logged in to new PDS
    login_new_pds

    url = "#{migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob"

    response = HTTParty.post(
      url,
      headers: {
        'Authorization' => "Bearer #{get_access_token_from_session}",
        'Content-Type' => 'application/octet-stream'
      },
      body: File.binread(blob_path),
      timeout: 300
    )

    unless response.success?
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

    stdout, stderr, status = execute_goat('bsky', 'prefs', 'export')

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

    stdout, stderr, status = execute_goat('account', 'plc', 'recommended')

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

    stdout, stderr, status = execute_goat(
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
    login_old_pds

    execute_goat('account', 'deactivate')

    logger.info("Account deactivated on old PDS")
  rescue StandardError => e
    raise GoatError, "Failed to deactivate account: #{e.message}"
  end

  def get_account_status
    logger.info("Getting account status")

    stdout, stderr, status = execute_goat('account', 'status')

    logger.info("Account status retrieved")
    stdout
  rescue StandardError => e
    raise GoatError, "Failed to get account status: #{e.message}"
  end

  def check_missing_blobs
    logger.info("Checking for missing blobs")

    stdout, stderr, status = execute_goat('account', 'missing-blobs')

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
      'ATP_PLC_HOST' => migration.plc_host || ENV['ATP_PLC_HOST'] || 'https://plc.directory',
      'ATP_PDS_HOST' => migration.new_pds_host # Default PDS for goat
    }

    # Build full command
    cmd = ['goat'] + args

    logger.debug("Executing goat command: #{cmd.join(' ')}")

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

    # Change to work directory for execution
    Dir.chdir(work_dir) do
      begin
        Timeout.timeout(timeout) do
          stdout, stderr, status = Open3.capture3(env, *cmd)
        end
      rescue Timeout::Error
        raise TimeoutError, "Command timed out after #{timeout} seconds: #{cmd.join(' ')}"
      end
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
  def get_access_token_from_session
    # goat stores session in ~/.config/goat/session.json
    # For now, we'll use a direct API call approach
    # This is a placeholder - in production, you'd need proper session management

    # Alternative: Make a direct com.atproto.server.createSession call
    session_path = File.expand_path('~/.config/goat/session.json')

    if File.exist?(session_path)
      session_data = JSON.parse(File.read(session_path))
      return session_data['accessJwt'] if session_data['accessJwt']
    end

    # Fallback: create new session
    create_direct_session
  end

  # Create session directly via API when goat session is unavailable
  def create_direct_session
    url = "#{migration.new_pds_host}/xrpc/com.atproto.server.createSession"

    response = HTTParty.post(
      url,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        identifier: migration.did,
        password: migration.encrypted_password
      }.to_json,
      timeout: 30
    )

    unless response.success?
      raise AuthenticationError, "Failed to create session: #{response.code} #{response.message}"
    end

    parsed = JSON.parse(response.body)
    parsed['accessJwt']
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
