# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GoatService, type: :service do
  let(:migration) do
    Migration.create!(
      email: "test@example.com",
      did: "did:plc:test123abc",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: "pending_account"
    )
  end

  let(:service) { described_class.new(migration) }
  let(:password) { "test_password_123" }

  before do
    migration.set_password(password, expires_in: 48.hours)
    # The old-PDS client is token-authenticated; without stored tokens every
    # example dies at "No old PDS refresh token available".
    migration.set_old_pds_tokens!(access_token: fake_jwt, refresh_token: fake_jwt(expires_at: 30.days.from_now))
    stub_pds_sessions(migration)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:debug)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
  end

  describe '#initialize' do
    it 'creates work directory for migration' do
      expect(File.exist?(service.work_dir)).to be true
    end

    it 'sets migration attribute' do
      expect(service.migration).to eq(migration)
    end
  end

  # The old PDS is reached with the tokens captured during the wizard, not with
  # a password - and over HTTP, not the goat CLI these examples used to drive.
  describe '#login_old_pds' do
    let(:refresh_url) { "#{migration.old_pds_host}/xrpc/com.atproto.server.refreshSession" }

    context 'when login succeeds' do
      it 'reuses a valid stored access token without re-authenticating' do
        service.login_old_pds

        expect(a_request(:post, refresh_url)).not_to have_been_made
      end

      it 'refreshes an expired access token' do
        migration.set_old_pds_tokens!(
          access_token: fake_jwt(expires_at: 1.hour.ago),
          refresh_token: fake_jwt(expires_at: 30.days.from_now)
        )

        service.login_old_pds

        expect(a_request(:post, refresh_url)).to have_been_made
      end

      it 'logs success message' do
        expect(Rails.logger).to receive(:info).with(/Successfully logged in to old PDS/)
        service.login_old_pds
      end
    end

    context 'when login fails' do
      before do
        migration.update!(old_access_token: nil, old_refresh_token: nil)
      end

      it 'raises AuthenticationError' do
        expect { service.login_old_pds }.to raise_error(
          GoatService::AuthenticationError,
          /Failed to login to old PDS/
        )
      end
    end
  end

  # No stored tokens for the new PDS in this fixture, so it takes the password
  # login path: a createSession call, not a goat CLI invocation.
  describe '#login_new_pds' do
    let(:create_session_url) { "#{migration.new_pds_host}/xrpc/com.atproto.server.createSession" }

    context 'when login succeeds' do
      it 'creates a session on the new PDS' do
        service.login_new_pds

        expect(a_request(:post, create_session_url)).to have_been_made
      end

      it 'caches the client rather than logging in twice' do
        service.login_new_pds
        service.login_new_pds

        expect(a_request(:post, create_session_url)).to have_been_made.once
      end
    end

    context 'when login fails' do
      before do
        stub_request(:post, create_session_url).to_return(
          status: 401,
          body: { error: 'AuthenticationRequired', message: 'Invalid identifier or password' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
      end

      it 'raises AuthenticationError' do
        expect { service.login_new_pds }.to raise_error(
          GoatService::AuthenticationError,
          /Failed to login to new PDS/
        )
      end
    end
  end

  describe '#get_service_auth_token' do
    let(:new_pds_did) { "did:plc:newpds123" }
    let(:auth_token) { "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..." }

    let(:service_auth_url) { "#{migration.old_pds_host}/xrpc/com.atproto.server.getServiceAuth" }

    context 'when successful' do
      before do
        stub_request(:get, service_auth_url)
          .with(query: hash_including('aud' => new_pds_did))
          .to_return(status: 200, body: { token: auth_token }.to_json,
                     headers: { 'Content-Type' => 'application/json' })
      end

      it 'returns service auth token' do
        expect(service.get_service_auth_token(new_pds_did)).to eq(auth_token)
      end

      it 'scopes the token to account creation on the target PDS' do
        service.get_service_auth_token(new_pds_did)

        expect(
          a_request(:get, service_auth_url).with(
            query: hash_including('aud' => new_pds_did,
                                  'lxm' => 'com.atproto.server.createAccount')
          )
        ).to have_been_made
      end
    end

    context 'when token is empty' do
      before do
        stub_request(:get, service_auth_url)
          .with(query: hash_including('aud' => new_pds_did))
          .to_return(status: 200, body: { token: '' }.to_json,
                     headers: { 'Content-Type' => 'application/json' })
      end

      # The blanket `rescue StandardError` re-wraps this as AuthenticationError.
      # That is still a GoatError subclass and the original message survives in
      # the wrapper, so both halves of this expectation hold.
      it 'raises GoatError' do
        expect { service.get_service_auth_token(new_pds_did) }.to raise_error(
          GoatService::GoatError,
          /Empty service auth token/
        )
      end
    end
  end

  describe '#create_account_on_new_pds' do
    let(:service_auth_token) { "test_token_123" }

    let(:create_account_url) { "#{migration.new_pds_host}/xrpc/com.atproto.server.createAccount" }

    context 'when account creation succeeds' do
      before do
        stub_request(:post, create_account_url)
          .to_return(status: 200, body: { did: migration.did, handle: migration.new_handle }.to_json,
                     headers: { 'Content-Type' => 'application/json' })
      end

      it 'creates the account with the existing DID and new handle' do
        service.create_account_on_new_pds(service_auth_token)

        expect(
          a_request(:post, create_account_url).with { |req|
            body = JSON.parse(req.body)
            body['did'] == migration.did &&
              body['handle'] == migration.new_handle &&
              req.headers['Authorization'] == "Bearer #{service_auth_token}"
          }
        ).to have_been_made
      end

      it 'logs success message' do
        expect(Rails.logger).to receive(:info).with(/Account created on new PDS/)
        service.create_account_on_new_pds(service_auth_token)
      end
    end

    context 'when account already exists' do
      before do
        stub_request(:post, create_account_url).to_return(
          status: 400,
          body: { error: 'AlreadyExists', message: 'Repo already exists' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
        allow(service).to receive(:check_account_exists_on_new_pds).and_return(
          { exists: true, deactivated: true }
        )
      end

      it 'raises AccountExistsError with helpful message' do
        expect { service.create_account_on_new_pds(service_auth_token) }.to raise_error(
          GoatService::AccountExistsError,
          /Orphaned deactivated account exists/
        )
      end
    end
  end

  describe '#export_repo' do
    let(:car_path) { service.work_dir.join("account.#{Time.now.to_i}.car") }

    # export_repo shells out to curl rather than using HTTParty, so WebMock
    # cannot intercept it. Stub the command and write the file curl would have.
    before do
      allow(service).to receive(:execute_command) do |*args, **_kwargs|
        File.write(args[args.index('-o') + 1], 'CAR_FILE_BINARY_CONTENT')
        ['', '', instance_double(Process::Status, success?: true, exitstatus: 0)]
      end
    end

    it 'downloads repository as CAR file' do
      result = service.export_repo

      expect(result).to be_a(String)
      expect(File.exist?(result)).to be true
    end

    it 'logs export progress' do
      expect(Rails.logger).to receive(:info).with(/Exporting repository/)
      expect(Rails.logger).to receive(:info).with(/Repository exported/)
      service.export_repo
    end

    context 'when export fails' do
      before do
        # curl exits without producing the file - a dead connection, a 404, a
        # full disk. export_repo notices the missing file rather than the exit
        # status, and wraps everything as GoatError.
        FileUtils.rm_rf(Dir[service.work_dir.join('*.car')])
        allow(service).to receive(:execute_command).and_return(
          ['', 'curl: (22) The requested URL returned error: 500',
           instance_double(Process::Status, success?: false, exitstatus: 22)]
        )
      end

      it 'raises GoatError' do
        expect { service.export_repo }.to raise_error(
          GoatService::GoatError,
          /Failed to export repository/
        )
      end
    end
  end

  describe '#import_repo' do
    let(:car_file) { service.work_dir.join("test.car") }

    before do
      FileUtils.mkdir_p(service.work_dir)
      File.write(car_file, "CAR_FILE_CONTENT")

      stub_request(:post, "#{migration.new_pds_host}/xrpc/com.atproto.repo.importRepo")
        .to_return(status: 200, body: '{"success":true}')
    end

    after do
      File.delete(car_file) if File.exist?(car_file)
    end

    it 'imports CAR file to new PDS' do
      service.import_repo(car_file)

      expect(WebMock).to have_requested(:post, "#{migration.new_pds_host}/xrpc/com.atproto.repo.importRepo")
    end

    it 'logs import progress' do
      expect(Rails.logger).to receive(:info).with(/Importing repository/)
      expect(Rails.logger).to receive(:info).with(/Repository imported/)
      service.import_repo(car_file)
    end

    context 'when CAR file does not exist' do
      it 'raises GoatError' do
        expect { service.import_repo('nonexistent.car') }.to raise_error(
          GoatService::GoatError,
          /CAR file not found/
        )
      end
    end
  end

  describe '#list_blobs' do
    let(:blob_list_response) do
      {
        cursor: "next_page",
        cids: ["bafyreiabc123", "bafyreiabc456"]
      }
    end

    before do
      stub_request(:get, "#{migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs")
        .with(query: hash_including(did: migration.did))
        .to_return(
          status: 200,
          body: blob_list_response.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'fetches blob list from old PDS' do
      result = service.list_blobs

      expect(result).to include('cursor', 'cids')
      expect(result['cids']).to eq(["bafyreiabc123", "bafyreiabc456"])
    end

    it 'supports cursor for pagination' do
      service.list_blobs("some_cursor")

      expect(WebMock).to have_requested(:get, "#{migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs")
        .with(query: hash_including(cursor: "some_cursor"))
    end
  end

  describe '#download_blob' do
    let(:cid) { "bafyreiabc123" }
    let(:blob_content) { "BINARY_BLOB_DATA" }

    before do
      stub_request(:get, "#{migration.old_pds_host}/xrpc/com.atproto.sync.getBlob")
        .with(query: { did: migration.did, cid: cid })
        .to_return(
          status: 200,
          body: blob_content,
          headers: { 'Content-Type' => 'image/jpeg' }
        )
    end

    it 'downloads blob and saves to disk' do
      blob_path = service.download_blob(cid)

      expect(File.exist?(blob_path)).to be true
      expect(File.read(blob_path)).to eq(blob_content)
    end

    it 'returns path to downloaded blob' do
      blob_path = service.download_blob(cid)

      expect(blob_path).to be_a(String)
      expect(blob_path).to include(cid)
    end

    context 'when download fails' do
      before do
        # Must repeat the query matcher: without it this stub never matches and
        # the success stub above answers instead.
        stub_request(:get, "#{migration.old_pds_host}/xrpc/com.atproto.sync.getBlob")
          .with(query: { did: migration.did, cid: cid })
          .to_return(status: 404, body: "Blob not found")
      end

      it 'raises NetworkError' do
        expect { service.download_blob(cid) }.to raise_error(
          GoatService::NetworkError,
          /Failed to download blob/
        )
      end
    end
  end

  describe '#upload_blob' do
    let(:blob_path) { service.work_dir.join("test_blob.jpg") }
    let(:blob_content) { "BINARY_BLOB_DATA" }

    before do
      FileUtils.mkdir_p(service.work_dir)
      File.write(blob_path, blob_content)

      stub_request(:post, "#{migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob")
        .to_return(
          status: 200,
          body: { blob: { '$type' => 'blob', ref: { '$link' => 'bafyreiabc123' },
                          mimeType: 'image/jpeg', size: 16 } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    after do
      File.delete(blob_path) if File.exist?(blob_path)
    end

    it 'uploads blob to new PDS' do
      service.upload_blob(blob_path)

      expect(WebMock).to have_requested(:post, "#{migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob")
    end

    it 'returns the parsed blob reference' do
      result = service.upload_blob(blob_path)

      expect(result.dig('blob', 'ref', '$link')).to eq("bafyreiabc123")
    end

    context 'when upload fails' do
      before do
        stub_request(:post, "#{migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob")
          .to_return(status: 500, body: "Upload failed")
      end

      it 'raises NetworkError' do
        expect { service.upload_blob(blob_path) }.to raise_error(
          GoatService::NetworkError,
          /Failed to upload blob/
        )
      end
    end
  end

  describe '#request_plc_token' do
    let(:request_token_url) do
      "#{migration.old_pds_host}/xrpc/com.atproto.identity.requestPlcOperationSignature"
    end

    before do
      stub_request(:post, request_token_url)
        .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    end

    it 'asks the old PDS to email a PLC operation signature token' do
      service.request_plc_token

      expect(a_request(:post, request_token_url)).to have_been_made
    end
  end

  describe '#get_recommended_plc_operation' do
    let(:plc_operation) do
      {
        "type" => "plc_operation",
        "rotationKeys" => ["did:key:abc123"],
        "verificationMethods" => {},
        "alsoKnownAs" => ["at://test.new.bsky.social"],
        "services" => {
          "atproto_pds" => {
            "type" => "AtprotoPersonalDataServer",
            "endpoint" => migration.new_pds_host
          }
        }
      }
    end

    before do
      allow(Open3).to receive(:capture3).and_return(
        [plc_operation.to_json, "", double(success?: true, exitstatus: 0)]
      )
    end

    # It writes the recommended credentials to disk and returns the path of the
    # unsigned copy, ready for the rotation key to be injected.
    it 'returns the path of the unsigned operation' do
      stub_request(:get, "#{migration.new_pds_host}/xrpc/com.atproto.identity.getRecommendedDidCredentials")
        .to_return(status: 200, body: plc_operation.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      result = service.get_recommended_plc_operation

      expect(result).to be_a(String)
      expect(result).to end_with('plc_unsigned.json')
      expect(JSON.parse(File.read(result))).to eq(plc_operation)
    end
  end

  describe '#sign_plc_operation' do
    let(:plc_token) { "plc_token_123" }
    let(:unsigned_op) do
      { "rotationKeys" => ["did:key:zRotation"], "alsoKnownAs" => ["at://#{migration.new_handle}"],
        "verificationMethods" => {}, "services" => {} }
    end
    let(:unsigned_op_path) do
      FileUtils.mkdir_p(service.work_dir)
      path = service.work_dir.join("plc_unsigned.json")
      File.write(path, unsigned_op.to_json)
      path.to_s
    end

    before do
      stub_request(:post, "#{migration.old_pds_host}/xrpc/com.atproto.identity.signPlcOperation")
        .to_return(status: 200,
                   body: { operation: { "type" => "plc_operation", "sig" => "signature_data" } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    end

    it 'signs the operation with the old PDS and writes the result to disk' do
      result = service.sign_plc_operation(unsigned_op_path, plc_token)

      expect(result).to be_a(String)
      expect(JSON.parse(File.read(result)).dig('operation', 'sig')).to eq('signature_data')
    end

    it 'refuses to sign without a token' do
      expect { service.sign_plc_operation(unsigned_op_path, nil) }
        .to raise_error(GoatService::GoatError, /token is required/i)
    end
  end

  describe '#submit_plc_operation' do
    # The signed operation goes to the *new PDS*, which relays it to the PLC
    # directory on the user's behalf - the service never talks to plc.directory
    # here, and it takes a path rather than the operation itself.
    let(:submit_url) { "#{migration.new_pds_host}/xrpc/com.atproto.identity.submitPlcOperation" }
    let(:signed_op_path) do
      FileUtils.mkdir_p(service.work_dir)
      path = service.work_dir.join("plc_signed.json")
      File.write(path, { operation: { "type" => "plc_operation", "sig" => "signature_data" } }.to_json)
      path.to_s
    end

    before do
      stub_request(:post, submit_url)
        .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    end

    it 'submits the signed operation via the new PDS' do
      service.submit_plc_operation(signed_op_path)

      expect(a_request(:post, submit_url)).to have_been_made
    end

    context 'when submission fails' do
      before do
        stub_request(:post, submit_url).to_return(
          status: 400,
          body: { error: 'InvalidRequest', message: 'Invalid operation' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
      end

      # Everything out of this method is wrapped as GoatError, NetworkError's
      # parent class.
      it 'raises GoatError' do
        expect { service.submit_plc_operation(signed_op_path) }.to raise_error(
          GoatService::GoatError,
          /Failed to submit PLC operation/
        )
      end
    end
  end

  describe '#activate_account' do
    before do
      stub_request(:post, "#{migration.new_pds_host}/xrpc/com.atproto.server.activateAccount")
        .to_return(status: 200, body: '{"success":true}')
    end

    it 'activates account on new PDS' do
      service.activate_account

      expect(WebMock).to have_requested(:post, "#{migration.new_pds_host}/xrpc/com.atproto.server.activateAccount")
    end
  end

  describe '#deactivate_account' do
    before do
      stub_request(:post, "#{migration.old_pds_host}/xrpc/com.atproto.server.deactivateAccount")
        .to_return(status: 200, body: '{"success":true}')
    end

    it 'deactivates account on old PDS' do
      service.deactivate_account

      expect(WebMock).to have_requested(:post, "#{migration.old_pds_host}/xrpc/com.atproto.server.deactivateAccount")
    end
  end

  describe '.cleanup_migration_files' do
    let(:did) { "did:plc:cleanup123" }
    let(:cleanup_dir) { Rails.root.join('tmp', 'goat', did) }

    before do
      FileUtils.mkdir_p(cleanup_dir)
      File.write(cleanup_dir.join("test.car"), "content")
      File.write(cleanup_dir.join("test.txt"), "content")
    end

    it 'removes all migration files for DID' do
      described_class.cleanup_migration_files(did)

      expect(File.exist?(cleanup_dir)).to be false
    end

    it 'logs cleanup action' do
      expect(Rails.logger).to receive(:info).with(/Cleaned up migration files/)
      described_class.cleanup_migration_files(did)
    end
  end

  describe 'error handling' do
    context 'when a shelled-out command times out' do
      before do
        allow(service).to receive(:execute_command)
          .and_raise(GoatService::TimeoutError, 'Command timed out after 660 seconds')
      end

      it 'surfaces the timeout from export_repo' do
        expect { service.export_repo }
          .to raise_error(GoatService::GoatError, /timed out/)
      end
    end

    context 'when API returns rate limit error' do
      before do
        stub_request(:get, "#{migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs")
          .with(query: hash_including('did' => migration.did))
          .to_return(status: 429, body: "Rate limit exceeded")
      end

      # list_blobs wraps this in with_rate_limit_retry, which sleeps between
      # attempts; assert on the request method so the classification is tested
      # without waiting out the backoff.
      it 'raises RateLimitError' do
        expect { service.list_blobs_request }.to raise_error(GoatService::RateLimitError)
      end
    end
  end
end
