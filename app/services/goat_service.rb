# GoatService - Core service for PDS migration operations
#
# This service uses minisky-based PDS clients and direct HTTP calls
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
#   - GoatError: General operation failures
#
# Work Files:
#   All temporary files stored in: Rails.root/tmp/goat/{did}/
#   - account.{timestamp}.car (repository export)
#   - blobs/{cid} (blob downloads)
#   - prefs.json (preferences)
#   - plc_*.json (PLC operation files)
#
# Requirements:
#   - Migration model with required fields (did, handles, hosts, password)
#   - Network access to both source and target PDS
#   - PLC directory access for DID updates

require 'open3'
require 'base58'
require 'minisky'

# PdsClient: A programmatic minisky client that doesn't require a config file
# Used for password-based authentication (new PDS only)
class PdsClient
  include Minisky::Requests

  attr_reader :host
  attr_accessor :config

  def initialize(host, identifier, password)
    @host = host
    @config = {
      'id' => identifier,
      'pass' => password
    }
  end

  def save_config
    # No-op: we don't persist config to disk
  end
end

# TokenPdsClient: A minisky client pre-authenticated with access/refresh tokens
# Used for old PDS where we store tokens instead of the user's password
class TokenPdsClient
  include Minisky::Requests

  attr_reader :host
  attr_accessor :config

  def initialize(host, identifier, access_token:, refresh_token:, on_token_refresh: nil)
    @host = host
    @on_token_refresh = on_token_refresh
    @config = {
      'id' => identifier,
      'access_token' => access_token,
      'refresh_token' => refresh_token
    }
  end

  def save_config
    # Persist refreshed tokens back to the migration record
    @on_token_refresh&.call(config['access_token'], config['refresh_token'])
  end
end

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

    # Create/retrieve minisky client (handles login automatically)
    old_pds_client

    logger.info("Successfully logged in to old PDS")
  rescue StandardError => e
    raise AuthenticationError, "Failed to login to old PDS: #{e.message}"
  end

  def login_new_pds
    logger.info("Logging in to new PDS: #{migration.new_pds_host}")

    # Clear any existing new PDS session first to avoid conflicts
    @pds_clients&.delete(:new_pds)

    # Use DID for login to new PDS
    password = migration.password
    logger.info("Password available: #{!password.nil?}, length: #{password&.length || 0}")

    # Create/retrieve minisky client (handles login automatically)
    new_pds_client

    logger.info("Successfully logged in to new PDS")
  rescue StandardError => e
    raise AuthenticationError, "Failed to login to new PDS: #{e.message}"
  end

  def logout_goat
    logger.debug("Clearing PDS sessions")
    clear_pds_clients
    @access_tokens = {}
  end

  # Account Creation Methods

  def get_service_auth_token(new_pds_did)
    logger.info("Getting service auth token for PDS: #{new_pds_did}")

    # Must be logged in to old PDS first
    response = old_pds_client.get_request('com.atproto.server.getServiceAuth', {
      aud: new_pds_did,
      lxm: 'com.atproto.server.createAccount',
      exp: (Time.now.to_i + 3600)
    })

    token = response['token']
    raise GoatError, "Empty service auth token received" if token.nil? || token.empty?

    logger.info("Service auth token obtained")
    token
  rescue StandardError => e
    raise AuthenticationError, "Failed to get service auth token: #{e.message}"
  end

  def check_account_exists_on_new_pds
    logger.info("Checking if account already exists on new PDS")

    url = "#{migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo"

    http_response = HTTParty.get(url, query: { repo: migration.did }, timeout: 30)
    response = JSON.parse(http_response.body) rescue {}

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

  def verify_existing_account_access
    logger.info("Verifying access to existing account on new PDS for migration_in")

    # Check if account exists
    account_status = check_account_exists_on_new_pds

    unless account_status[:exists]
      raise GoatError, "Account does not exist on target PDS. For migration_in (returning to existing PDS), " \
        "the account must already exist. DID: #{migration.did}, PDS: #{migration.new_pds_host}"
    end

    # Try to login - this will fail if password is wrong or account is inaccessible
    login_new_pds

    logger.info("Successfully verified access to existing account (deactivated: #{account_status[:deactivated]})")

    account_status
  rescue StandardError => e
    raise AuthenticationError, "Failed to verify access to existing account: #{e.message}"
  end

  def create_account_on_new_pds(service_auth_token)
    logger.info("Creating account on new PDS with existing DID")

    # Build request body
    body = {
      did: migration.did,
      handle: migration.new_handle,
      password: migration.password,
      email: migration.email
    }

    # Add invite code if present
    if migration.invite_code.present?
      logger.info("Including invite code for account creation")
      body[:inviteCode] = migration.invite_code
    end

    # Use raw HTTParty - service auth token goes in Authorization header
    response = HTTParty.post(
      "#{migration.new_pds_host}/xrpc/com.atproto.server.createAccount",
      headers: {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{service_auth_token}"
      },
      body: body.to_json,
      timeout: 60
    )

    unless response.success?
      error_body = JSON.parse(response.body) rescue {}
      error_message = error_body['message'] || error_body['error'] || "HTTP #{response.code}"

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

    logger.info("Account created on new PDS")
  rescue AccountExistsError
    raise
  rescue StandardError => e
    raise GoatError, "Failed to create account on new PDS: #{e.message}"
  end

  # Rotation Key Methods

  def generate_rotation_key
    logger.info("Generating rotation key for account recovery")

    # Generate P-256 (prime256v1/secp256r1) key pair using OpenSSL
    ec_key = OpenSSL::PKey::EC.generate('prime256v1')

    # Get compressed public key (33 bytes: 1 byte prefix + 32 bytes X coordinate)
    public_point = ec_key.public_key.to_octet_string(:compressed)

    # Get private key as 32-byte scalar (zero-padded if needed)
    private_key_bn = ec_key.private_key
    private_key_bytes = private_key_bn.to_s(2).rjust(32, "\x00")

    # Encode public key as did:key with P-256 multicodec prefix
    # P-256 public key multicodec: 0x1200 (varint encoded as 0x80, 0x24)
    # See: https://github.com/multiformats/multicodec/blob/master/table.csv
    p256_public_prefix = [0x80, 0x24].pack('C*')
    public_key_with_prefix = p256_public_prefix + public_point
    public_multibase = 'z' + Base58.binary_to_base58(public_key_with_prefix, :bitcoin)
    public_key_did = "did:key:#{public_multibase}"

    # Encode private key in multibase format
    # P-256 private key multicodec: 0x1306 (varint encoded as 0x86, 0x26)
    p256_private_prefix = [0x86, 0x26].pack('C*')
    private_key_with_prefix = p256_private_prefix + private_key_bytes
    private_multibase = 'z' + Base58.binary_to_base58(private_key_with_prefix, :bitcoin)

    logger.info("Rotation key generated successfully")

    {
      private_key: private_multibase,
      public_key: public_key_did
    }
  rescue StandardError => e
    raise GoatError, "Failed to generate rotation key: #{e.message}"
  end

  def add_rotation_key_to_pds(public_key)
    logger.info("Adding rotation key to PDS account (highest priority)")

    # Get current recommended DID credentials from new PDS
    recommended = new_pds_client.get_request('com.atproto.identity.getRecommendedDidCredentials', {})

    # Add the new rotation key at the front (highest priority)
    rotation_keys = recommended['rotationKeys'] || []
    rotation_keys = [public_key] + rotation_keys.reject { |k| k == public_key }

    # Sign the PLC operation with updated rotation keys via the new PDS
    # Note: This requires the PDS to have signing authority
    signed_response = new_pds_client.post_request('com.atproto.identity.signPlcOperation', {
      rotationKeys: rotation_keys,
      alsoKnownAs: recommended['alsoKnownAs'],
      verificationMethods: recommended['verificationMethods'],
      services: recommended['services']
    })

    # Submit the signed operation to PLC
    new_pds_client.post_request('com.atproto.identity.submitPlcOperation', {
      operation: signed_response['operation']
    })

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

    # Ensure we're logged in to new PDS
    login_new_pds

    # Get access token from minisky client
    access_token = new_pds_client.user.access_token

    # Binary upload requires HTTParty since minisky/PDS client is JSON-focused
    response = HTTParty.post(
      "#{migration.new_pds_host}/xrpc/com.atproto.repo.importRepo",
      headers: {
        'Content-Type' => 'application/vnd.ipld.car',
        'Authorization' => "Bearer #{access_token}"
      },
      body: File.binread(car_path),
      timeout: 600  # 10 minutes for large repos
    )

    unless response.success?
      error_body = JSON.parse(response.body) rescue {}
      error_message = error_body['message'] || error_body['error'] || "HTTP #{response.code}"
      raise GoatError, "Repository import failed: #{error_message}"
    end

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

    # Get preferences via PDS client
    response = old_pds_client.get_request('app.bsky.actor.getPreferences', {})

    File.write(prefs_path, response.to_json)

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

    # Read preferences from file
    prefs_data = JSON.parse(File.read(prefs_path))

    # Import preferences via PDS client
    new_pds_client.post_request('app.bsky.actor.putPreferences', {
      preferences: prefs_data['preferences']
    })

    logger.info("Preferences imported successfully")
  rescue StandardError => e
    raise GoatError, "Failed to import preferences: #{e.message}"
  end

  # PLC Methods

  def request_plc_token
    logger.info("Requesting PLC token from old PDS")

    # Must be logged in to old PDS
    login_old_pds

    # Request PLC operation signature token via email
    # Note: This endpoint doesn't accept a request body, so we don't pass the data parameter
    old_pds_client.post_request('com.atproto.identity.requestPlcOperationSignature')

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

    # Get recommended DID credentials from new PDS via PDS client
    response = new_pds_client.get_request('com.atproto.identity.getRecommendedDidCredentials', {})

    File.write(plc_recommended_path, response.to_json)

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

    # Read unsigned operation
    unsigned_op = JSON.parse(File.read(unsigned_op_path))

    # Sign PLC operation via old PDS using the email token
    response = old_pds_client.post_request('com.atproto.identity.signPlcOperation', {
      token: token,
      rotationKeys: unsigned_op['rotationKeys'],
      alsoKnownAs: unsigned_op['alsoKnownAs'],
      verificationMethods: unsigned_op['verificationMethods'],
      services: unsigned_op['services']
    })

    File.write(plc_signed_path, response.to_json)

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

    # Read signed operation
    signed_op = JSON.parse(File.read(signed_op_path))

    # Submit PLC operation via new PDS
    new_pds_client.post_request('com.atproto.identity.submitPlcOperation', {
      operation: signed_op['operation']
    })

    logger.info("PLC operation submitted successfully")
  rescue StandardError => e
    raise GoatError, "Failed to submit PLC operation: #{e.message}"
  end

  # Account Status Methods

  def activate_account
    logger.info("Activating account on new PDS")

    # Must be logged in to new PDS
    login_new_pds

    # Activate account via PDS client (no request body expected)
    new_pds_client.post_request('com.atproto.server.activateAccount')

    logger.info("Account activated on new PDS")
  rescue StandardError => e
    raise GoatError, "Failed to activate account: #{e.message}"
  end

  def deactivate_account
    logger.info("Deactivating account on old PDS")

    # Must be logged in to old PDS
    login_old_pds

    # Deactivate account via PDS client (no request body expected)
    old_pds_client.post_request('com.atproto.server.deactivateAccount')

    logger.info("Account deactivated on old PDS")
  rescue StandardError => e
    raise GoatError, "Failed to deactivate account: #{e.message}"
  end

  def get_account_status
    logger.info("Getting account status")

    # Get account status via PDS client
    response = new_pds_client.get_request('com.atproto.server.checkAccountStatus', {})

    logger.info("Account status retrieved")
    response.to_json
  rescue StandardError => e
    raise GoatError, "Failed to get account status: #{e.message}"
  end

  def check_missing_blobs
    logger.info("Checking for missing blobs")

    # Check missing blobs via PDS client
    response = new_pds_client.get_request('com.atproto.repo.listMissingBlobs', {})

    logger.info("Missing blobs check completed")
    response.to_json
  rescue StandardError => e
    raise GoatError, "Failed to check missing blobs: #{e.message}"
  end

  # Cleanup Methods

  def cleanup
    # Remove all migration work files
    self.class.cleanup_migration_files(migration.did)
  end

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

  # Execute shell command with timeout (used for curl in export_repo)
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

  # Get access token from session cache or create new session
  # @param pds_host [String] The PDS host to get a token for (old or new PDS)
  # @param identifier [String] The identifier to use for login (handle or DID)
  def get_access_token_from_session(pds_host:, identifier:)
    # Use cache key based on PDS host to support both old and new PDS
    cache_key = "#{pds_host}:#{identifier}"

    # Return cached token if available
    return @access_tokens[cache_key] if @access_tokens[cache_key]

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

  # Create session directly via API
  # For old PDS: uses stored refresh token
  # For new PDS: uses system-generated password
  # @param pds_host [String] The PDS host to authenticate against
  # @param identifier [String] The identifier to use for login (handle or DID)
  def create_direct_session(pds_host:, identifier:)
    if old_pds_host?(pds_host)
      # Old PDS: refresh session using stored refresh token
      tokens = refresh_session_with_token(
        host: pds_host,
        refresh_token: migration.old_refresh_token
      )
      # Persist rotated tokens back to migration record
      migration.update_old_pds_tokens!(
        access_token: tokens[:access_token],
        refresh_token: tokens[:refresh_token]
      )
      tokens[:access_token]
    else
      # New PDS: create session using system-generated password
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
        if response.code == 429
          logger.warn("Rate limit hit during session creation: #{response.code} #{response.message}")
          raise RateLimitError, "Failed to create session: #{response.code} #{response.message}"
        end
        raise AuthenticationError, "Failed to create session: #{response.code} #{response.message}"
      end

      parsed = JSON.parse(response.body)
      parsed['accessJwt']
    end
  rescue RateLimitError
    raise  # Re-raise rate limit errors
  rescue StandardError => e
    raise AuthenticationError, "Failed to create direct session: #{e.message}"
  end

  # Check if a host is the old (source) PDS
  def old_pds_host?(host)
    host == migration.old_pds_host
  end

  # Refresh an ATProto session using a refresh token
  # Returns { access_token:, refresh_token: } with fresh tokens
  def refresh_session_with_token(host:, refresh_token:)
    raise AuthenticationError, "No refresh token available for #{host}" if refresh_token.blank?

    url = "#{host}/xrpc/com.atproto.server.refreshSession"

    response = HTTParty.post(
      url,
      headers: {
        'Authorization' => "Bearer #{refresh_token}"
      },
      timeout: 30
    )

    unless response.success?
      if response.code == 429
        raise RateLimitError, "Rate limit during session refresh: #{response.code} #{response.message}"
      end
      raise AuthenticationError, "Failed to refresh session on #{host}: #{response.code} #{response.message}"
    end

    parsed = JSON.parse(response.body)
    {
      access_token: parsed['accessJwt'],
      refresh_token: parsed['refreshJwt']
    }
  rescue RateLimitError
    raise
  rescue AuthenticationError
    raise
  rescue StandardError => e
    raise AuthenticationError, "Failed to refresh session: #{e.message}"
  end

  # Create a TokenPdsClient for old PDS using stored tokens
  # Refreshes the access token first to ensure it's valid
  def create_token_authenticated_client(host:, identifier:)
    logger.info("Creating token-authenticated PDS client for #{host} (#{identifier})")

    refresh_token = migration.old_refresh_token
    raise AuthenticationError, "No old PDS refresh token available" if refresh_token.blank?

    # Refresh to get fresh tokens (access token may have expired between jobs)
    tokens = refresh_session_with_token(host: host, refresh_token: refresh_token)

    # Persist rotated tokens back to migration record
    migration.update_old_pds_tokens!(
      access_token: tokens[:access_token],
      refresh_token: tokens[:refresh_token]
    )

    # Create client with fresh tokens and a callback to persist future refreshes
    client = TokenPdsClient.new(
      host,
      identifier,
      access_token: tokens[:access_token],
      refresh_token: tokens[:refresh_token],
      on_token_refresh: ->(access, refresh) {
        migration.update_old_pds_tokens!(access_token: access, refresh_token: refresh)
      }
    )

    logger.info("Token-authenticated PDS client created for #{host}")
    client
  rescue StandardError => e
    raise AuthenticationError, "Failed to create token-authenticated client for #{host}: #{e.message}"
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

  # PDS client management using minisky
  # Returns a cached TokenPdsClient for the old (source) PDS
  # Uses stored refresh token to obtain fresh access tokens
  def old_pds_client
    @pds_clients ||= {}
    @pds_clients[:old_pds] ||= create_token_authenticated_client(
      host: migration.old_pds_host,
      identifier: migration.old_handle
    )
  end

  # Returns a cached PdsClient for the new (target) PDS
  # For migration_in, uses stored tokens (like old_pds_client) instead of password
  def new_pds_client
    @pds_clients ||= {}
    @pds_clients[:new_pds] ||= if migration.has_new_pds_tokens?
      create_new_pds_token_client
    else
      create_pds_client(
        host: migration.new_pds_host,
        identifier: migration.did,
        password: migration.password
      )
    end
  end

  # Creates a token-authenticated client for the new (target) PDS
  # Used for migration_in where we have pre-authenticated tokens from the wizard
  def create_new_pds_token_client
    logger.info("Creating token-authenticated client for new PDS: #{migration.new_pds_host}")

    refresh_token = migration.new_refresh_token
    raise AuthenticationError, "No new PDS refresh token available" if refresh_token.blank?

    # Refresh to get fresh tokens
    tokens = refresh_session_with_token(host: migration.new_pds_host, refresh_token: refresh_token)

    # Persist rotated tokens
    migration.update_new_pds_tokens!(
      access_token: tokens[:access_token],
      refresh_token: tokens[:refresh_token]
    )

    client = TokenPdsClient.new(
      migration.new_pds_host,
      migration.did,
      access_token: tokens[:access_token],
      refresh_token: tokens[:refresh_token],
      on_token_refresh: ->(access, refresh) {
        migration.update_new_pds_tokens!(access_token: access, refresh_token: refresh)
      }
    )

    logger.info("Token-authenticated client created for new PDS")
    client
  rescue StandardError => e
    raise AuthenticationError, "Failed to create token-authenticated client for new PDS: #{e.message}"
  end

  # Creates a new PdsClient and authenticates
  def create_pds_client(host:, identifier:, password:)
    logger.info("Creating PDS client for #{host} (#{identifier})")

    client = PdsClient.new(host, identifier, password)

    # Perform login to get tokens
    client.log_in

    logger.info("PDS client authenticated for #{host}")
    client
  rescue StandardError => e
    raise AuthenticationError, "Failed to create PDS client for #{host}: #{e.message}"
  end

  # Clear cached PDS clients (e.g., after logout)
  def clear_pds_clients
    @pds_clients = {}
  end

  # Class methods for handle resolution

  # Resolve a handle to a DID
  # Tries multiple resolution methods in order:
  # 1. DNS TXT record (_atproto.handle)
  # 2. HTTPS well-known endpoint (/.well-known/atproto-did)
  # 3. PDS resolution endpoint
  def self.resolve_handle_to_did(handle)
    Rails.logger.info("Resolving handle to DID: #{handle}")

    # Strategy 1: Try DNS-based resolution (most reliable for custom domains)
    begin
      # Extract the domain from the handle for DNS TXT record lookup
      domain = handle.strip.downcase
      txt_record = "_atproto.#{domain}"

      Rails.logger.debug("Attempting DNS TXT lookup for #{txt_record}")
      require 'resolv'
      resolver = Resolv::DNS.new

      txt_records = resolver.getresources(txt_record, Resolv::DNS::Resource::IN::TXT)
      txt_records.each do |record|
        record.strings.each do |string|
          if string.start_with?('did=')
            did = string.sub('did=', '')
            Rails.logger.info("Resolved handle #{handle} to DID via DNS: #{did}")
            return did
          end
        end
      end
    rescue StandardError => e
      Rails.logger.debug("DNS resolution failed for #{handle}: #{e.message}")
      # Continue to next strategy
    end

    # Strategy 2: Try resolution via inferred PDS (for handles like user.pds.example.com)
    if handle.include?('.pds.')
      begin
        # Extract potential PDS host from handle (e.g., euro11-06.pds.local.theeverythingapp.de -> pds.local.theeverythingapp.de)
        parts = handle.split('.')
        if parts.length >= 3
          # Reconstruct PDS host from domain parts
          pds_host = "https://#{parts[1..-1].join('.')}"
          Rails.logger.debug("Attempting resolution via inferred PDS: #{pds_host}")

          url = "#{pds_host}/xrpc/com.atproto.identity.resolveHandle"
          response = HTTParty.get(url, query: { handle: handle }, timeout: 10)

          if response.success?
            parsed = JSON.parse(response.body)
            did = parsed['did']
            Rails.logger.info("Resolved handle #{handle} to DID via inferred PDS #{pds_host}: #{did}")
            return did
          end
        end
      rescue StandardError => e
        Rails.logger.debug("Inferred PDS resolution failed: #{e.message}")
        # Continue to next strategy
      end
    end

    # Strategy 3: Try resolution via common PDS instances (for bsky.social handles)
    common_pds_hosts = ['https://bsky.social', 'https://bsky.network']

    common_pds_hosts.each do |pds_host|
      begin
        url = "#{pds_host}/xrpc/com.atproto.identity.resolveHandle"
        response = HTTParty.get(url, query: { handle: handle }, timeout: 10)

        if response.success?
          parsed = JSON.parse(response.body)
          did = parsed['did']
          Rails.logger.info("Resolved handle #{handle} to DID via #{pds_host}: #{did}")
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

  # Detect if a handle is DNS-verified (custom domain) or PDS-hosted
  # Returns a hash with { type: 'dns_verified' | 'pds_hosted', verified_via: 'dns' | 'http_wellknown' | 'pds_api' }
  #
  # A handle is PDS-hosted if its domain suffix matches the PDS hostname
  # (e.g., user.pds.example.com is hosted by pds.example.com).
  # A handle is DNS-verified (custom domain) only if the user owns the domain
  # independently of any PDS.
  def self.detect_handle_type(handle)
    Rails.logger.info("Detecting handle type for: #{handle}")

    # Normalize handle
    domain = handle.strip.downcase

    # Check for common PDS-hosted domain patterns
    pds_hosted_suffixes = [
      '.bsky.social',
      '.blacksky.app',
      '.staging.bsky.dev',
      '.test.bsky.network'
    ]

    # If handle ends with known PDS-hosted suffix, it's definitely PDS-hosted
    if pds_hosted_suffixes.any? { |suffix| domain.end_with?(suffix) }
      Rails.logger.info("Handle #{handle} identified as PDS-hosted (known suffix)")
      return {
        type: 'pds_hosted',
        verified_via: 'pds_api',
        can_preserve: false,
        reason: 'This handle is hosted by the PDS provider and cannot be transferred'
      }
    end

    # Check if the handle's domain suffix matches the source PDS hostname.
    # For handles like "user.pds.example.com", the PDS is "pds.example.com".
    # These are PDS-hosted handles even though they have DNS records (set by the PDS).
    if handle_matches_source_pds?(domain)
      Rails.logger.info("Handle #{handle} identified as PDS-hosted (domain suffix matches source PDS)")
      return {
        type: 'pds_hosted',
        verified_via: 'pds_api',
        can_preserve: false,
        reason: 'This handle is hosted by the PDS provider and cannot be transferred'
      }
    end

    # Try DNS TXT record lookup
    begin
      txt_record = "_atproto.#{domain}"
      Rails.logger.debug("Attempting DNS TXT lookup for #{txt_record}")

      require 'resolv'
      resolver = Resolv::DNS.new
      txt_records = resolver.getresources(txt_record, Resolv::DNS::Resource::IN::TXT)

      txt_records.each do |record|
        record.strings.each do |string|
          if string.start_with?('did=')
            Rails.logger.info("Handle #{handle} identified as DNS-verified (DNS TXT record found)")
            return {
              type: 'dns_verified',
              verified_via: 'dns',
              can_preserve: true,
              dns_record: string
            }
          end
        end
      end
    rescue StandardError => e
      Rails.logger.debug("DNS lookup failed for #{handle}: #{e.message}")
      # Continue to check HTTP well-known
    end

    # Try HTTP well-known endpoint
    begin
      url = "https://#{domain}/.well-known/atproto-did"
      Rails.logger.debug("Attempting HTTP well-known lookup at #{url}")

      response = HTTParty.get(url, timeout: 5, follow_redirects: true)

      if response.success? && response.body&.start_with?('did:')
        Rails.logger.info("Handle #{handle} identified as custom domain (HTTP well-known)")
        return {
          type: 'dns_verified',
          verified_via: 'http_wellknown',
          can_preserve: true
        }
      end
    rescue StandardError => e
      Rails.logger.debug("HTTP well-known lookup failed for #{handle}: #{e.message}")
      # Continue
    end

    # If no DNS or HTTP well-known found, it's likely PDS-hosted
    Rails.logger.info("Handle #{handle} identified as PDS-hosted (no DNS/well-known found)")
    {
      type: 'pds_hosted',
      verified_via: 'pds_api',
      can_preserve: false,
      reason: 'This handle is hosted by the PDS provider and cannot be transferred'
    }
  rescue StandardError => e
    Rails.logger.warn("Error detecting handle type for #{handle}: #{e.message}")
    # Default to PDS-hosted on error
    {
      type: 'pds_hosted',
      verified_via: 'unknown',
      can_preserve: false,
      reason: 'Could not verify handle type'
    }
  end

  # Check if a handle's domain suffix matches its source PDS hostname.
  # PDS-hosted handles use the PDS hostname as their domain suffix
  # (e.g., "user.pds.example.com" is hosted by "pds.example.com").
  # This distinguishes PDS-hosted handles from genuinely user-owned custom domains.
  def self.handle_matches_source_pds?(handle)
    parts = handle.split('.')
    return false if parts.length < 3

    # Try to resolve the handle to find its PDS
    begin
      did = resolve_handle_to_did(handle)
      pds_host = resolve_did_to_pds(did)

      # Extract hostname from PDS URL
      pds_hostname = URI.parse(pds_host).host&.downcase
      return false unless pds_hostname

      # Check if the handle's domain suffix matches the PDS hostname
      # e.g., "euro11-06.pds.local.theeverythingapp.de" ends with "pds.local.theeverythingapp.de"
      handle.end_with?(".#{pds_hostname}")
    rescue StandardError => e
      Rails.logger.debug("Could not check PDS match for #{handle}: #{e.message}")

      # Fallback: check if the handle looks like it's hosted on a PDS
      # by checking if removing the first part gives a hostname with "pds" in it
      suffix = parts[1..].join('.')
      suffix.include?('pds.') || suffix.start_with?('pds.')
    end
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
