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

  describe '#login_old_pds' do
    context 'when login succeeds' do
      before do
        allow(Open3).to receive(:capture3).and_return(
          ["Success", "", double(success?: true, exitstatus: 0)]
        )
      end

      it 'executes goat login command with old PDS credentials' do
        expect(Open3).to receive(:capture3).with(
          hash_including("GOAT_CONFIG" => anything),
          /account login/,
          hash_including(timeout: anything)
        )

        service.login_old_pds
      end

      it 'logs success message' do
        expect(Rails.logger).to receive(:info).with(/Successfully logged in to old PDS/)
        service.login_old_pds
      end
    end

    context 'when login fails' do
      before do
        allow(Open3).to receive(:capture3).and_return(
          ["", "Invalid credentials", double(success?: false, exitstatus: 1)]
        )
      end

      it 'raises AuthenticationError' do
        expect { service.login_old_pds }.to raise_error(
          GoatService::AuthenticationError,
          /Failed to login to old PDS/
        )
      end
    end
  end

  describe '#login_new_pds' do
    context 'when login succeeds' do
      before do
        allow(Open3).to receive(:capture3).and_return(
          ["Success", "", double(success?: true, exitstatus: 0)]
        )
      end

      it 'logs out first to clear session' do
        expect(service).to receive(:logout_goat)
        service.login_new_pds
      end

      it 'executes goat login command with DID' do
        allow(service).to receive(:logout_goat)

        expect(Open3).to receive(:capture3).with(
          hash_including("GOAT_CONFIG" => anything),
          /account login.*#{migration.did}/,
          hash_including(timeout: anything)
        )

        service.login_new_pds
      end
    end

    context 'when login fails' do
      before do
        allow(service).to receive(:logout_goat)
        allow(Open3).to receive(:capture3).and_return(
          ["", "Invalid credentials", double(success?: false, exitstatus: 1)]
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

    context 'when successful' do
      before do
        allow(Open3).to receive(:capture3).and_return(
          [auth_token, "", double(success?: true, exitstatus: 0)]
        )
      end

      it 'returns service auth token' do
        result = service.get_service_auth_token(new_pds_did)
        expect(result).to eq(auth_token)
      end

      it 'includes correct parameters' do
        expect(Open3).to receive(:capture3).with(
          hash_including("GOAT_CONFIG" => anything),
          /account service-auth.*--lxm com.atproto.server.createAccount.*--aud #{new_pds_did}/m,
          hash_including(timeout: anything)
        )

        service.get_service_auth_token(new_pds_did)
      end
    end

    context 'when token is empty' do
      before do
        allow(Open3).to receive(:capture3).and_return(
          ["", "", double(success?: true, exitstatus: 0)]
        )
      end

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

    context 'when account creation succeeds' do
      before do
        allow(Open3).to receive(:capture3).and_return(
          ["Account created", "", double(success?: true, exitstatus: 0)]
        )
      end

      it 'creates account with correct parameters' do
        expect(Open3).to receive(:capture3).with(
          hash_including("GOAT_CONFIG" => anything),
          /account create.*--existing-did #{migration.did}.*--handle #{migration.new_handle}/m,
          hash_including(timeout: anything)
        )

        service.create_account_on_new_pds(service_auth_token)
      end

      it 'logs success message' do
        expect(Rails.logger).to receive(:info).with(/Account created on new PDS/)
        service.create_account_on_new_pds(service_auth_token)
      end
    end

    context 'when account already exists' do
      before do
        allow(Open3).to receive(:capture3).and_return(
          ["", "AlreadyExists: Repo already exists", double(success?: false, exitstatus: 1)]
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

    before do
      # Mock HTTP request for repo export
      stub_request(:get, "#{migration.old_pds_host}/xrpc/com.atproto.sync.getRepo")
        .with(query: { did: migration.did })
        .to_return(
          status: 200,
          body: "CAR_FILE_BINARY_CONTENT",
          headers: { 'Content-Type' => 'application/vnd.ipld.car' }
        )
    end

    it 'downloads repository as CAR file' do
      result = service.export_repo
      expect(result).to be_a(Pathname)
      expect(File.exist?(result)).to be true
    end

    it 'logs export progress' do
      expect(Rails.logger).to receive(:info).with(/Exporting repository/)
      expect(Rails.logger).to receive(:info).with(/Repository exported/)
      service.export_repo
    end

    context 'when export fails' do
      before do
        stub_request(:get, "#{migration.old_pds_host}/xrpc/com.atproto.sync.getRepo")
          .to_return(status: 500, body: "Internal Server Error")
      end

      it 'raises NetworkError' do
        expect { service.export_repo }.to raise_error(
          GoatService::NetworkError,
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

      expect(result).to include(:cursor, :cids)
      expect(result[:cids]).to eq(["bafyreiabc123", "bafyreiabc456"])
    end

    it 'supports cursor for pagination' do
      service.list_blobs(cursor: "some_cursor")

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
      expect(blob_path).to be_a(Pathname)
      expect(blob_path.to_s).to include(cid)
    end

    context 'when download fails' do
      before do
        stub_request(:get, "#{migration.old_pds_host}/xrpc/com.atproto.sync.getBlob")
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
          body: { blob: { cid: "bafyreiabc123" } }.to_json,
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

    it 'returns blob CID' do
      result = service.upload_blob(blob_path)
      expect(result).to eq("bafyreiabc123")
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
    before do
      allow(Open3).to receive(:capture3).and_return(
        ["PLC token requested via email", "", double(success?: true, exitstatus: 0)]
      )
    end

    it 'requests PLC token via goat' do
      expect(Open3).to receive(:capture3).with(
        hash_including("GOAT_CONFIG" => anything),
        /account plc request-token/,
        hash_including(timeout: anything)
      )

      service.request_plc_token
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

    it 'returns recommended PLC operation' do
      result = service.get_recommended_plc_operation
      expect(result).to be_a(Hash)
      expect(result['type']).to eq('plc_operation')
    end
  end

  describe '#sign_plc_operation' do
    let(:unsigned_op) { { "type" => "plc_operation" } }
    let(:plc_token) { "plc_token_123" }
    let(:signed_op) { { "type" => "plc_operation", "sig" => "signature_data" } }

    before do
      allow(Open3).to receive(:capture3).and_return(
        [signed_op.to_json, "", double(success?: true, exitstatus: 0)]
      )
    end

    it 'signs PLC operation with token' do
      result = service.sign_plc_operation(unsigned_op, plc_token)
      expect(result).to be_a(Hash)
      expect(result['sig']).to be_present
    end
  end

  describe '#submit_plc_operation' do
    let(:signed_op) { { "type" => "plc_operation", "sig" => "signature_data" } }

    before do
      stub_request(:post, "https://plc.directory/#{migration.did}")
        .to_return(
          status: 200,
          body: '{"success":true}',
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'submits signed operation to PLC directory' do
      service.submit_plc_operation(signed_op)

      expect(WebMock).to have_requested(:post, "https://plc.directory/#{migration.did}")
    end

    context 'when submission fails' do
      before do
        stub_request(:post, "https://plc.directory/#{migration.did}")
          .to_return(status: 400, body: "Invalid operation")
      end

      it 'raises NetworkError' do
        expect { service.submit_plc_operation(signed_op) }.to raise_error(
          GoatService::NetworkError,
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
      expect(Rails.logger).to receive(:info).with(/Cleaning up migration files/)
      described_class.cleanup_migration_files(did)
    end
  end

  describe 'error handling' do
    context 'when goat command times out' do
      before do
        allow(Open3).to receive(:capture3).and_raise(Timeout::Error)
      end

      it 'raises TimeoutError' do
        expect { service.login_old_pds }.to raise_error(GoatService::TimeoutError)
      end
    end

    context 'when API returns rate limit error' do
      before do
        stub_request(:get, "#{migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs")
          .to_return(status: 429, body: "Rate limit exceeded")
      end

      it 'raises RateLimitError' do
        expect { service.list_blobs }.to raise_error(GoatService::RateLimitError)
      end
    end
  end
end
