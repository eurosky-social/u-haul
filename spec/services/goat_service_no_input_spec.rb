# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GoatService, 'no-input procedures and account creation' do
  let(:migration) do
    Migration.create!(
      email: "test@example.com",
      did: "did:plc:test#{SecureRandom.hex(6)}",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: :pending_account
    )
  end
  let(:service) { described_class.new(migration) }

  before do
    migration.set_password('secret', expires_in: 48.hours)
    allow(service).to receive(:sleep)
  end

  describe '#post_no_input' do
    let(:client) { double('PdsClient') }
    let(:framing_error) do
      Minisky::ClientErrorResponse.new(
        400, 'Bad Request',
        { 'error' => 'InvalidRequest', 'message' => 'A request body was provided when none was expected' }
      )
    end

    it 'retries the transient body-framing rejection and succeeds' do
      calls = 0
      allow(client).to receive(:post_request_without_body) do
        calls += 1
        raise framing_error if calls < 3
        {}
      end

      result = service.send(:post_no_input, client, 'com.atproto.identity.requestPlcOperationSignature')

      expect(result).to eq({})
      expect(calls).to eq(3)
    end

    it 'gives up after the configured number of attempts' do
      allow(client).to receive(:post_request_without_body).and_raise(framing_error)

      expect {
        service.send(:post_no_input, client, 'com.atproto.server.activateAccount', attempts: 2)
      }.to raise_error(Minisky::ClientErrorResponse, /request body was provided/)
      expect(client).to have_received(:post_request_without_body).twice
    end

    it 'does not retry other client errors' do
      other = Minisky::ClientErrorResponse.new(401, 'Unauthorized', { 'error' => 'AuthenticationRequired', 'message' => 'nope' })
      allow(client).to receive(:post_request_without_body).and_raise(other)

      expect {
        service.send(:post_no_input, client, 'com.atproto.server.activateAccount')
      }.to raise_error(other)
      expect(client).to have_received(:post_request_without_body).once
    end
  end

  describe '#create_account_on_new_pds' do
    let(:create_url) { "https://new.pds.example/xrpc/com.atproto.server.createAccount" }
    let(:describe_url) { %r{https://new\.pds\.example/xrpc/com\.atproto\.repo\.describeRepo} }
    let(:json) { { 'Content-Type' => 'application/json' } }

    def stub_already_exists_deactivated
      stub_request(:post, create_url)
        .to_return(status: 400, body: { error: 'AlreadyExists', message: 'Repo already exists' }.to_json, headers: json)
      stub_request(:get, describe_url)
        .to_return(status: 400, body: { error: 'RepoDeactivated', message: 'Repo has been deactivated' }.to_json, headers: json)
    end

    it 'treats a deactivated account this migration already created as success' do
      migration.progress_data['account_created_at'] = 5.minutes.ago.iso8601
      migration.save!
      stub_already_exists_deactivated

      expect { service.create_account_on_new_pds('service-token') }.not_to raise_error
    end

    it 'still reports an orphan when this migration never created the account' do
      stub_already_exists_deactivated

      expect { service.create_account_on_new_pds('service-token') }
        .to raise_error(GoatService::AccountExistsError, /Orphaned deactivated account/)
    end

    it 'raises EmailTakenError when the email is already registered' do
      stub_request(:post, create_url)
        .to_return(status: 400, body: { error: 'InvalidRequest', message: 'Email already taken: test@example.com' }.to_json, headers: json)

      expect { service.create_account_on_new_pds('service-token') }
        .to raise_error(GoatService::EmailTakenError, /already used by another account/)
    end
  end
end
