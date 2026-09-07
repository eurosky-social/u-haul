# frozen_string_literal: true

require 'rails_helper'

# The blob path's failures are the ones that get counted, so they have to be
# distinguishable. Before this, every failure arrived as a NetworkError whose
# only distinguishing feature was a sentence, which made "how many 500s?" a
# log-grepping exercise.
RSpec.describe GoatService, 'blob transfer errors' do
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: 'did:plc:test123abc',
      old_handle: 'test.old.bsky.social',
      old_pds_host: 'https://old.pds.example',
      new_handle: 'test.new.bsky.social',
      new_pds_host: 'https://new.pds.example',
      status: 'pending_account'
    )
  end

  let(:service) { described_class.new(migration) }
  let(:cid) { 'bafyreiabc123' }
  let(:upload_url) { "#{migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob" }
  let(:download_url) { "#{migration.old_pds_host}/xrpc/com.atproto.sync.getBlob" }

  before do
    migration.set_password('test_password_123', expires_in: 48.hours)
    migration.set_old_pds_tokens!(access_token: fake_jwt,
                                  refresh_token: fake_jwt(expires_at: 30.days.from_now))
    stub_pds_sessions(migration)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:debug)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
    # Rate-limit retries sleep; nothing here should wait out real backoff.
    allow(service).to receive(:sleep)
  end

  describe '#upload_blob' do
    let(:blob_path) { service.work_dir.join(cid) }

    before do
      FileUtils.mkdir_p(service.work_dir)
      File.write(blob_path, 'BINARY_BLOB_DATA')
    end

    after { FileUtils.rm_f(blob_path) }

    it 'carries the HTTP status of a rejected upload' do
      stub_request(:post, upload_url).to_return(status: 500, body: 'InternalServerError: boom')

      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::NetworkError) { |error|
        expect(error.http_status).to eq(500)
        expect(error.phase).to eq(:upload)
        expect(error.cid).to eq(cid)
        expect(error.body_snippet).to include('InternalServerError')
      }
    end

    it 'does not double up the message prefix when it re-raises' do
      stub_request(:post, upload_url).to_return(status: 500, body: 'boom')

      expect { service.upload_blob(blob_path) }.to raise_error(
        GoatService::NetworkError, /\AFailed to upload blob: 500/
      )
    end

    it 'raises TimeoutError, not NetworkError, when the upload stalls' do
      stub_request(:post, upload_url).to_timeout

      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::TimeoutError) { |error|
        expect(error.phase).to eq(:upload)
        expect(error.cid).to eq(cid)
      }
    end

    it 'still classifies rate limiting separately, with its retry hint' do
      stub_request(:post, upload_url)
        .to_return(status: 429, headers: { 'Retry-After' => '42' }, body: 'slow down')

      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::RateLimitError) { |error|
        expect(error.retry_after).to eq(42)
        expect(error.http_status).to eq(429)
      }
    end
  end

  describe '#download_blob' do
    it 'carries the HTTP status of a refused download' do
      stub_request(:get, download_url)
        .with(query: { did: migration.did, cid: cid })
        .to_return(status: 404, body: 'Blob not found')

      expect { service.download_blob(cid) }.to raise_error(GoatService::NetworkError) { |error|
        expect(error.http_status).to eq(404)
        expect(error.phase).to eq(:download)
      }
    end

    it 'raises TimeoutError when the old PDS stops responding' do
      stub_request(:get, download_url)
        .with(query: { did: migration.did, cid: cid })
        .to_timeout

      expect { service.download_blob(cid) }.to raise_error(GoatService::TimeoutError)
    end
  end

  describe '#target_pds_version' do
    it 'reads the version the target PDS reports' do
      stub_request(:get, "#{migration.new_pds_host}/xrpc/_health")
        .to_return(status: 200, body: { version: '0.5.29' }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      expect(service.target_pds_version).to eq('0.5.29')
    end

    it 'returns nil rather than raising when the endpoint is unreachable' do
      stub_request(:get, "#{migration.new_pds_host}/xrpc/_health").to_timeout

      expect(service.target_pds_version).to be_nil
    end

    it 'asks only once per service instance' do
      stub_request(:get, "#{migration.new_pds_host}/xrpc/_health")
        .to_return(status: 200, body: { version: '0.5.29' }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      3.times { service.target_pds_version }

      expect(WebMock).to have_requested(:get, "#{migration.new_pds_host}/xrpc/_health").once
    end
  end
end
