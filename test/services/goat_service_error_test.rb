require "test_helper"
require "webmock/minitest"

# GoatService Error Handling Tests
# Tests based on MIGRATION_ERROR_ANALYSIS.md covering all possible errors
# across all migration stages
#
# NOTE: The service now uses minisky for PDS client management and HTTParty
# for direct HTTP calls. Tests use WebMock to stub HTTP requests.
class GoatServiceErrorTest < ActiveSupport::TestCase
  def setup
    @migration = migrations(:pending_migration)
    # Set a test password that Lockbox can encrypt/decrypt
    @migration.set_password("test_password_123")
    @service = GoatService.new(@migration)

    # Disable all external HTTP connections
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # ============================================================================
  # Stage 2: Authentication Errors
  # ============================================================================

  test "login_old_pds raises AuthenticationError on wrong password" do
    stub_request(:post, "#{@migration.old_pds_host}/xrpc/com.atproto.server.createSession")
      .with(body: hash_including(identifier: @migration.old_handle))
      .to_return(status: 401, body: { error: 'AuthenticationRequired', message: 'Invalid identifier or password' }.to_json)

    error = assert_raises(GoatService::AuthenticationError) do
      @service.login_old_pds
    end

    assert_match /Failed to login to old PDS/, error.message
  end

  test "login_old_pds raises AuthenticationError when PDS unreachable" do
    stub_request(:post, "#{@migration.old_pds_host}/xrpc/com.atproto.server.createSession")
      .to_timeout

    error = assert_raises(GoatService::AuthenticationError) do
      @service.login_old_pds
    end

    assert_match /Failed to login to old PDS/, error.message
  end

  test "login_new_pds raises AuthenticationError on credentials expired" do
    @migration.update!(credentials_expires_at: 1.hour.ago)

    # Password should return nil due to expiration
    assert_nil @migration.password

    error = assert_raises(GoatService::AuthenticationError) do
      @service.login_new_pds
    end

    # Should fail because password is nil
    assert_match /Failed to login to new PDS/, error.message
  end

  # ============================================================================
  # Stage 2: Account Creation Errors
  # ============================================================================

  test "get_service_auth_token raises AuthenticationError on failure" do
    # First stub login to old PDS
    stub_old_pds_login

    # Then stub service auth to fail
    stub_request(:get, /#{Regexp.escape(@migration.old_pds_host)}.*com\.atproto\.server\.getServiceAuth/)
      .to_return(status: 401, body: { error: 'AuthenticationRequired', message: 'service auth denied' }.to_json)

    error = assert_raises(GoatService::AuthenticationError) do
      @service.get_service_auth_token('did:web:newpds.com')
    end

    assert_match /Failed to get service auth token/, error.message
  end

  test "get_service_auth_token raises error on empty token" do
    stub_old_pds_login

    stub_request(:get, /#{Regexp.escape(@migration.old_pds_host)}.*com\.atproto\.server\.getServiceAuth/)
      .to_return(status: 200, body: { token: '' }.to_json, headers: { 'Content-Type' => 'application/json' })

    error = assert_raises(GoatService::GoatError) do
      @service.get_service_auth_token('did:web:newpds.com')
    end

    assert_match /Empty service auth token/, error.message
  end

  test "check_account_exists_on_new_pds detects orphaned deactivated account" do
    stub_request(:get, "#{@migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo")
      .with(query: { repo: @migration.did })
      .to_return(status: 400, body: { error: 'RepoDeactivated' }.to_json)

    result = @service.check_account_exists_on_new_pds

    assert result[:exists]
    assert result[:deactivated]
  end

  test "check_account_exists_on_new_pds detects active existing account" do
    stub_request(:get, "#{@migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo")
      .with(query: { repo: @migration.did })
      .to_return(status: 200, body: { did: @migration.did, handle: 'existing.handle.com' }.to_json)

    result = @service.check_account_exists_on_new_pds

    assert result[:exists]
    assert_not result[:deactivated]
    assert_equal 'existing.handle.com', result[:handle]
  end

  test "create_account_on_new_pds raises AccountExistsError for orphaned account" do
    # Stub account creation to fail with AlreadyExists
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createAccount")
      .to_return(status: 400, body: { error: 'AlreadyExists', message: 'Repo already exists' }.to_json)

    # Stub check to confirm deactivated account
    stub_request(:get, "#{@migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo")
      .with(query: { repo: @migration.did })
      .to_return(status: 400, body: { error: 'RepoDeactivated' }.to_json)

    error = assert_raises(GoatService::AccountExistsError) do
      @service.create_account_on_new_pds('test-token')
    end

    assert_match /Orphaned deactivated account/, error.message
    assert_match /delete the account from the PDS database/, error.message
  end

  test "create_account_on_new_pds raises AccountExistsError for active account" do
    # The code checks for "AlreadyExists" or "Repo already exists" in the message
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createAccount")
      .to_return(status: 400, body: { error: 'AlreadyExists', message: 'AlreadyExists: Account already active' }.to_json)

    stub_request(:get, "#{@migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo")
      .with(query: { repo: @migration.did })
      .to_return(status: 200, body: { did: @migration.did, handle: 'existing.handle.com' }.to_json)

    error = assert_raises(GoatService::AccountExistsError) do
      @service.create_account_on_new_pds('test-token')
    end

    assert_match /Active account already exists/, error.message
  end

  test "create_account_on_new_pds includes invite code when present" do
    @migration.set_invite_code('test-invite-code')

    # Expect the invite code to be included in the request
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createAccount")
      .with(body: hash_including(inviteCode: 'test-invite-code'))
      .to_return(status: 200, body: { did: @migration.did, handle: @migration.new_handle }.to_json)

    assert_nothing_raised do
      @service.create_account_on_new_pds('test-token')
    end
  end

  test "create_account_on_new_pds raises GoatError for invalid invite code" do
    @migration.set_invite_code('invalid-code')

    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createAccount")
      .to_return(status: 400, body: { error: 'InvalidInviteCode', message: 'Invite code is invalid or expired' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.create_account_on_new_pds('test-token')
    end

    assert_match /Failed to create account/, error.message
    # The error message contains "Invite code is invalid or expired" from the response
    assert_match /Invite code is invalid or expired/, error.message
  end

  # ============================================================================
  # Stage 2: Rate Limiting Errors
  # ============================================================================

  test "login_old_pds raises AuthenticationError with rate limit info on HTTP 429" do
    stub_request(:post, "#{@migration.old_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(status: 429, body: { error: 'RateLimitExceeded', message: 'Too Many Requests' }.to_json)

    error = assert_raises(GoatService::AuthenticationError) do
      @service.login_old_pds
    end

    assert_match /Failed to login to old PDS/, error.message
  end

  # ============================================================================
  # Stage 3: Repository Export/Import Errors
  # ============================================================================

  test "import_repo raises GoatError when CAR file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.import_repo('/nonexistent/path.car')
    end

    assert_match /CAR file not found/, error.message
  end

  test "import_repo raises GoatError on import failure" do
    car_path = @service.work_dir.join('test.car')
    File.write(car_path, 'test data')

    stub_new_pds_login

    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.repo.importRepo")
      .to_return(status: 400, body: { error: 'InvalidRepo', message: 'invalid CAR format' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.import_repo(car_path.to_s)
    end

    assert_match /Failed to import repository/, error.message
  ensure
    FileUtils.rm_f(car_path) if car_path
  end

  # ============================================================================
  # Stage 4: Blob Transfer Errors (Most Complex)
  # ============================================================================

  test "list_blobs raises RateLimitError on HTTP 429" do
    stub_request(:get, "#{@migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs")
      .with(query: { did: @migration.did })
      .to_return(status: 429, body: { error: 'RateLimitExceeded' }.to_json)

    error = assert_raises(GoatService::RateLimitError) do
      @service.list_blobs
    end

    assert_match /rate limit exceeded/, error.message
  end

  test "list_blobs raises NetworkError on non-success response" do
    stub_request(:get, "#{@migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs")
      .with(query: { did: @migration.did })
      .to_return(status: 500, body: { error: 'InternalServerError' }.to_json)

    error = assert_raises(GoatService::NetworkError) do
      @service.list_blobs
    end

    assert_match /Failed to list blobs/, error.message
  end

  test "list_blobs includes cursor parameter when provided" do
    cursor = "next_page_cursor"
    stub_request(:get, "#{@migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs")
      .with(query: { did: @migration.did, cursor: cursor })
      .to_return(status: 200, body: { cids: [], cursor: nil }.to_json)

    result = @service.list_blobs(cursor)

    assert_equal [], result['cids']
  end

  test "download_blob raises RateLimitError on HTTP 429" do
    cid = "bafybeiabc123"
    stub_request(:get, "#{@migration.old_pds_host}/xrpc/com.atproto.sync.getBlob")
      .with(query: { did: @migration.did, cid: cid })
      .to_return(status: 429, body: "")

    error = assert_raises(GoatService::RateLimitError) do
      @service.download_blob(cid)
    end

    assert_match /rate limit exceeded/, error.message
  end

  test "download_blob raises NetworkError on 404 (blob not found)" do
    cid = "bafybeimissing"
    stub_request(:get, "#{@migration.old_pds_host}/xrpc/com.atproto.sync.getBlob")
      .with(query: { did: @migration.did, cid: cid })
      .to_return(status: 404, body: { error: 'BlobNotFound' }.to_json)

    error = assert_raises(GoatService::NetworkError) do
      @service.download_blob(cid)
    end

    assert_match /Failed to download blob/, error.message
  end

  test "upload_blob raises RateLimitError on HTTP 429" do
    blob_path = @service.work_dir.join('blobs', 'test_blob')
    FileUtils.mkdir_p(blob_path.dirname)
    File.binwrite(blob_path, 'test blob data')

    # Pre-populate access token to avoid login
    @service.instance_variable_get(:@access_tokens)["#{@migration.new_pds_host}:#{@migration.did}"] = 'test-token'

    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob")
      .to_return(status: 429, body: { error: 'RateLimitExceeded' }.to_json)

    error = assert_raises(GoatService::RateLimitError) do
      @service.upload_blob(blob_path.to_s)
    end

    assert_match /rate limit exceeded/, error.message
  ensure
    FileUtils.rm_rf(blob_path.dirname) if blob_path
  end

  test "upload_blob raises GoatError when blob file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.upload_blob('/nonexistent/blob')
    end

    assert_match /Blob file not found/, error.message
  end

  # ============================================================================
  # Stage 5: Preferences Import/Export Errors
  # ============================================================================

  test "export_preferences raises GoatError on failure" do
    stub_old_pds_login

    stub_request(:get, /#{Regexp.escape(@migration.old_pds_host)}.*app\.bsky\.actor\.getPreferences/)
      .to_return(status: 500, body: { error: 'InternalServerError', message: 'failed to export preferences' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.export_preferences
    end

    assert_match /Failed to export preferences/, error.message
  end

  test "import_preferences raises GoatError when prefs file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.import_preferences('/nonexistent/prefs.json')
    end

    assert_match /Preferences file not found/, error.message
  end

  test "import_preferences raises GoatError on import failure" do
    prefs_path = @service.work_dir.join('prefs.json')
    File.write(prefs_path, '{"preferences": []}')

    stub_new_pds_login

    stub_request(:post, /#{Regexp.escape(@migration.new_pds_host)}.*app\.bsky\.actor\.putPreferences/)
      .to_return(status: 400, body: { error: 'InvalidRequest', message: 'invalid preferences format' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.import_preferences(prefs_path.to_s)
    end

    assert_match /Failed to import preferences/, error.message
  ensure
    FileUtils.rm_f(prefs_path) if prefs_path
  end

  # ============================================================================
  # Stage 6: PLC Token Errors
  # ============================================================================

  test "request_plc_token raises GoatError on failure" do
    stub_old_pds_login

    stub_request(:post, /#{Regexp.escape(@migration.old_pds_host)}.*com\.atproto\.identity\.requestPlcOperationSignature/)
      .to_return(status: 400, body: { error: 'InvalidRequest', message: 'PLC token request denied' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.request_plc_token
    end

    assert_match /Failed to request PLC token/, error.message
  end

  # ============================================================================
  # Stage 7: PLC Operation Errors (CRITICAL)
  # ============================================================================

  test "get_recommended_plc_operation raises GoatError on failure" do
    stub_new_pds_login

    stub_request(:get, /#{Regexp.escape(@migration.new_pds_host)}.*com\.atproto\.identity\.getRecommendedDidCredentials/)
      .to_return(status: 500, body: { error: 'InternalServerError', message: 'failed to get recommended parameters' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.get_recommended_plc_operation
    end

    assert_match /Failed to get recommended PLC operation/, error.message
  end

  test "sign_plc_operation raises GoatError when unsigned file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.sign_plc_operation('/nonexistent/unsigned.json', 'token123')
    end

    assert_match /Unsigned PLC operation file not found/, error.message
  end

  test "sign_plc_operation raises GoatError when token is nil" do
    unsigned_path = @service.work_dir.join('plc_unsigned.json')
    File.write(unsigned_path, '{}')

    error = assert_raises(GoatService::GoatError) do
      @service.sign_plc_operation(unsigned_path.to_s, nil)
    end

    assert_match /PLC token is required/, error.message
  ensure
    FileUtils.rm_f(unsigned_path) if unsigned_path
  end

  test "sign_plc_operation raises GoatError when token is empty" do
    unsigned_path = @service.work_dir.join('plc_unsigned.json')
    File.write(unsigned_path, '{}')

    error = assert_raises(GoatService::GoatError) do
      @service.sign_plc_operation(unsigned_path.to_s, "")
    end

    assert_match /PLC token is required/, error.message
  ensure
    FileUtils.rm_f(unsigned_path) if unsigned_path
  end

  test "sign_plc_operation raises GoatError on signing failure" do
    unsigned_path = @service.work_dir.join('plc_unsigned.json')
    File.write(unsigned_path, '{"rotationKeys": [], "alsoKnownAs": [], "verificationMethods": {}, "services": {}}')

    stub_old_pds_login

    stub_request(:post, /#{Regexp.escape(@migration.old_pds_host)}.*com\.atproto\.identity\.signPlcOperation/)
      .to_return(status: 400, body: { error: 'InvalidToken', message: 'invalid PLC token' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.sign_plc_operation(unsigned_path.to_s, 'invalid-token')
    end

    assert_match /Failed to sign PLC operation/, error.message
  ensure
    FileUtils.rm_f(unsigned_path) if unsigned_path
  end

  test "submit_plc_operation raises GoatError when signed file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.submit_plc_operation('/nonexistent/signed.json')
    end

    assert_match /Signed PLC operation file not found/, error.message
  end

  test "submit_plc_operation raises GoatError on submission failure" do
    signed_path = @service.work_dir.join('plc_signed.json')
    File.write(signed_path, '{"operation": {}}')

    stub_new_pds_login

    stub_request(:post, /#{Regexp.escape(@migration.new_pds_host)}.*com\.atproto\.identity\.submitPlcOperation/)
      .to_return(status: 400, body: { error: 'InvalidSignature', message: 'PLC directory rejected operation' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.submit_plc_operation(signed_path.to_s)
    end

    assert_match /Failed to submit PLC operation/, error.message
  ensure
    FileUtils.rm_f(signed_path) if signed_path
  end

  # ============================================================================
  # Stage 8: Account Activation/Deactivation Errors
  # ============================================================================

  test "activate_account raises GoatError on failure" do
    stub_new_pds_login

    stub_request(:post, /#{Regexp.escape(@migration.new_pds_host)}.*com\.atproto\.server\.activateAccount/)
      .to_return(status: 400, body: { error: 'InvalidRequest', message: 'activation failed' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.activate_account
    end

    assert_match /Failed to activate account/, error.message
  end

  test "deactivate_account raises GoatError on failure" do
    stub_old_pds_login

    stub_request(:post, /#{Regexp.escape(@migration.old_pds_host)}.*com\.atproto\.server\.deactivateAccount/)
      .to_return(status: 400, body: { error: 'InvalidRequest', message: 'deactivation failed' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.deactivate_account
    end

    assert_match /Failed to deactivate account/, error.message
  end

  # ============================================================================
  # Rotation Key Generation
  # ============================================================================

  test "generate_rotation_key returns valid key pair" do
    result = @service.generate_rotation_key

    assert result[:private_key].present?, "Should have private key"
    assert result[:public_key].present?, "Should have public key"
    assert result[:private_key].start_with?('z'), "Private key should be base58btc encoded"
    assert result[:public_key].start_with?('did:key:z'), "Public key should be did:key format"
  end

  test "add_rotation_key_to_pds raises GoatError on failure" do
    stub_new_pds_login

    stub_request(:get, /#{Regexp.escape(@migration.new_pds_host)}.*com\.atproto\.identity\.getRecommendedDidCredentials/)
      .to_return(status: 200, body: { rotationKeys: [], alsoKnownAs: [], verificationMethods: {}, services: {} }.to_json)

    stub_request(:post, /#{Regexp.escape(@migration.new_pds_host)}.*com\.atproto\.identity\.signPlcOperation/)
      .to_return(status: 400, body: { error: 'InvalidRequest', message: 'failed to add rotation key' }.to_json)

    error = assert_raises(GoatService::GoatError) do
      @service.add_rotation_key_to_pds('did:key:test')
    end

    assert_match /Failed to add rotation key/, error.message
  end

  # ============================================================================
  # Network & Timeout Errors
  # ============================================================================

  test "execute_command raises TimeoutError when command exceeds timeout" do
    # Mock Open3.capture3 to raise Timeout::Error
    Open3.stubs(:capture3).raises(Timeout::Error)

    error = assert_raises(GoatService::TimeoutError) do
      @service.send(:execute_command, 'sleep', '10', timeout: 1)
    end

    assert_match /Command timed out/, error.message
  end

  # ============================================================================
  # DID/Handle Resolution Errors
  # ============================================================================

  test "resolve_handle_to_did raises NetworkError when handle not found" do
    # Stub DNS lookup to fail
    Resolv::DNS.any_instance.stubs(:getresources).returns([])

    # Stub HTTParty.get for all resolution attempts
    stub_request(:get, "https://bsky.social/xrpc/com.atproto.identity.resolveHandle")
      .with(query: { handle: 'nonexistent.handle.com' })
      .to_return(status: 404, body: "")

    stub_request(:get, "https://bsky.network/xrpc/com.atproto.identity.resolveHandle")
      .with(query: { handle: 'nonexistent.handle.com' })
      .to_return(status: 404, body: "")

    error = assert_raises(GoatService::NetworkError) do
      GoatService.resolve_handle_to_did('nonexistent.handle.com')
    end

    assert_match /Could not resolve handle/, error.message
  end

  test "resolve_did_to_pds raises NetworkError when DID document not found" do
    stub_request(:get, "https://plc.directory/did:plc:nonexistent")
      .to_return(status: 404, body: { error: 'NotFound' }.to_json)

    error = assert_raises(GoatService::NetworkError) do
      GoatService.resolve_did_to_pds('did:plc:nonexistent')
    end

    assert_match /Failed to fetch DID document/, error.message
  end

  test "resolve_did_to_pds raises GoatError when no PDS endpoint in DID document" do
    stub_request(:get, "https://plc.directory/did:plc:test")
      .to_return(status: 200, body: { did: 'did:plc:test', service: [] }.to_json)

    error = assert_raises(GoatService::GoatError) do
      GoatService.resolve_did_to_pds('did:plc:test')
    end

    assert_match /No PDS endpoint found/, error.message
  end

  # ============================================================================
  # Helper Methods
  # ============================================================================

  private

  # Generate a mock JWT that minisky can parse for expiration checks
  # Minisky uses Base64.decode64 (not urlsafe), so we need standard base64
  def mock_jwt(exp: nil)
    exp ||= (Time.now.to_i + 3600)  # Default: 1 hour from now
    header = Base64.strict_encode64({ alg: 'HS256', typ: 'JWT' }.to_json)
    payload = Base64.strict_encode64({ sub: 'test', exp: exp }.to_json)
    signature = Base64.strict_encode64('mock-signature')
    "#{header}.#{payload}.#{signature}"
  end

  def stub_old_pds_login
    stub_request(:post, "#{@migration.old_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(status: 200, body: {
        did: @migration.did,
        handle: @migration.old_handle,
        accessJwt: mock_jwt,
        refreshJwt: mock_jwt
      }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_new_pds_login
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(status: 200, body: {
        did: @migration.did,
        handle: @migration.new_handle,
        accessJwt: mock_jwt,
        refreshJwt: mock_jwt
      }.to_json, headers: { 'Content-Type' => 'application/json' })
  end
end
