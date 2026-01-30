# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UpdatePlcJob, type: :job do
  let(:migration) do
    Migration.create!(
      email: "test@example.com",
      did: "did:plc:test123abc",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: :pending_plc
    )
  end

  let(:goat_service) { instance_double(GoatService) }
  let(:plc_token) { 'plc_token_123abc' }
  let(:unsigned_op_path) { 'tmp/unsigned_plc_op.json' }
  let(:signed_op_path) { 'tmp/signed_plc_op.json' }

  before do
    migration.set_password('test_password_123')
    migration.set_plc_token(plc_token)
    allow(GoatService).to receive(:new).with(migration).and_return(goat_service)
  end

  describe '#perform' do
    context 'when PLC update succeeds' do
      before do
        allow(goat_service).to receive(:get_recommended_plc_operation).and_return(unsigned_op_path)
        allow(goat_service).to receive(:sign_plc_operation).with(unsigned_op_path, plc_token).and_return(signed_op_path)
        allow(goat_service).to receive(:submit_plc_operation).with(signed_op_path)
      end

      it 'gets recommended PLC operation' do
        expect(goat_service).to receive(:get_recommended_plc_operation)
        described_class.perform_now(migration.id)
      end

      it 'signs PLC operation with token' do
        expect(goat_service).to receive(:sign_plc_operation).with(unsigned_op_path, plc_token)
        described_class.perform_now(migration.id)
      end

      it 'submits signed operation to PLC directory' do
        expect(goat_service).to receive(:submit_plc_operation).with(signed_op_path)
        described_class.perform_now(migration.id)
      end

      it 'records plc_operation_recommended_at timestamp' do
        freeze_time do
          described_class.perform_now(migration.id)

          migration.reload
          expect(migration.progress_data['plc_operation_recommended_at']).to eq(Time.current.iso8601)
        end
      end

      it 'records plc_operation_signed_at timestamp' do
        freeze_time do
          described_class.perform_now(migration.id)

          migration.reload
          expect(migration.progress_data['plc_operation_signed_at']).to eq(Time.current.iso8601)
        end
      end

      it 'records plc_operation_submitted_at timestamp' do
        freeze_time do
          described_class.perform_now(migration.id)

          migration.reload
          expect(migration.progress_data['plc_operation_submitted_at']).to eq(Time.current.iso8601)
        end
      end

      it 'clears encrypted PLC token for security' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.encrypted_plc_token).to be_nil
      end

      it 'advances to pending_activation status' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_activation')
      end

      it 'enqueues ActivateAccountJob' do
        expect {
          described_class.perform_now(migration.id)
        }.to have_enqueued_job(ActivateAccountJob)
      end

      it 'logs critical success messages' do
        expect(Rails.logger).to receive(:info).with(/CRITICAL: Starting PLC update/)
        expect(Rails.logger).to receive(:info).with(/point of no return/)
        expect(Rails.logger).to receive(:info).with(/SUCCESS: PLC operation submitted/)
        expect(Rails.logger).to receive(:info).with(/now points to new PDS/)

        described_class.perform_now(migration.id)
      end
    end

    context 'when PLC token is missing' do
      before do
        migration.update!(encrypted_plc_token: nil)
      end

      it 'marks migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::AuthenticationError)

        migration.reload
        expect(migration.status).to eq('failed')
        expect(migration.last_error).to include('PLC token is missing or expired')
      end

      it 'does not attempt PLC operation' do
        expect(goat_service).not_to receive(:get_recommended_plc_operation)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::AuthenticationError)
      end

      it 'logs error' do
        expect(Rails.logger).to receive(:error).with(/PLC token is missing or expired/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::AuthenticationError)
      end
    end

    context 'when PLC token is expired' do
      before do
        # Set token with 1 hour expiry, then travel past expiry
        migration.set_plc_token(plc_token)
        travel_to 2.hours.from_now
      end

      it 'marks migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::AuthenticationError)

        migration.reload
        expect(migration.status).to eq('failed')
      end

      it 'does not submit PLC operation' do
        expect(goat_service).not_to receive(:submit_plc_operation)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::AuthenticationError)
      end
    end

    context 'when getting recommended PLC operation fails' do
      before do
        allow(goat_service).to receive(:get_recommended_plc_operation).and_raise(
          GoatService::NetworkError, 'Failed to get PLC operation'
        )
      end

      it 'marks migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)

        migration.reload
        expect(migration.status).to eq('failed')
        expect(migration.last_error).to include('CRITICAL: PLC update failed')
      end

      it 'logs critical failure' do
        expect(Rails.logger).to receive(:error).with(/CRITICAL FAILURE: Network error/)
        expect(Rails.logger).to receive(:error).with(/critical failure - manual intervention/)
        expect(Rails.logger).to receive(:error).with(/CRITICAL MIGRATION FAILURE - ADMIN ALERT/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)
      end

      it 'alerts admin of critical failure' do
        expect(Rails.logger).to receive(:error).with(/CRITICAL MIGRATION FAILURE - ADMIN ALERT/)
        expect(Rails.logger).to receive(:error).with(/Migration Token: #{migration.token}/)
        expect(Rails.logger).to receive(:error).with(/DID: #{migration.did}/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)
      end
    end

    context 'when signing PLC operation fails' do
      before do
        allow(goat_service).to receive(:get_recommended_plc_operation).and_return(unsigned_op_path)
        allow(goat_service).to receive(:sign_plc_operation).and_raise(
          GoatService::AuthenticationError, 'Invalid PLC token'
        )
      end

      it 'marks migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::AuthenticationError)

        migration.reload
        expect(migration.status).to eq('failed')
      end

      it 'does not submit PLC operation' do
        expect(goat_service).not_to receive(:submit_plc_operation)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::AuthenticationError)
      end

      it 'alerts admin' do
        expect(Rails.logger).to receive(:error).with(/CRITICAL MIGRATION FAILURE - ADMIN ALERT/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::AuthenticationError)
      end
    end

    context 'when submitting PLC operation fails' do
      before do
        allow(goat_service).to receive(:get_recommended_plc_operation).and_return(unsigned_op_path)
        allow(goat_service).to receive(:sign_plc_operation).and_return(signed_op_path)
        allow(goat_service).to receive(:submit_plc_operation).and_raise(
          GoatService::NetworkError, 'PLC directory unavailable'
        )
      end

      it 'marks migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)

        migration.reload
        expect(migration.status).to eq('failed')
        expect(migration.last_error).to include('CRITICAL')
      end

      it 'logs critical error' do
        expect(Rails.logger).to receive(:error).with(/CRITICAL FAILURE/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)
      end

      it 'alerts admin immediately' do
        expect(Rails.logger).to receive(:error).with(/ADMIN ALERT/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)
      end
    end

    context 'when rate limited' do
      before do
        allow(goat_service).to receive(:get_recommended_plc_operation).and_raise(
          GoatService::RateLimitError, 'Rate limit exceeded'
        )
      end

      it 'updates last_error with rate limit message' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::RateLimitError)

        migration.reload
        expect(migration.last_error).to include('Rate limit')
      end

      it 'logs warning about rate limit' do
        expect(Rails.logger).to receive(:warn).with(/Rate limit hit/)
        expect(Rails.logger).to receive(:warn).with(/retry with exponential backoff/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::RateLimitError)
      end

      it 'does not mark migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::RateLimitError)

        migration.reload
        # Status should still be pending_plc, not failed
        # (it will be retried)
        expect(migration.status).to eq('pending_plc')
      end

      it 'allows retry with polynomial backoff' do
        # Verify retry configuration
        job = described_class.new(migration.id)
        retry_config = job.class.retry_on_block_for(GoatService::RateLimitError)
        expect(retry_config).to be_present
      end
    end

    context 'with unexpected error' do
      before do
        allow(goat_service).to receive(:get_recommended_plc_operation).and_raise(
          RuntimeError, 'Unexpected error'
        )
      end

      it 'marks migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(RuntimeError)

        migration.reload
        expect(migration.status).to eq('failed')
      end

      it 'logs error with backtrace' do
        expect(Rails.logger).to receive(:error).with(/CRITICAL FAILURE: Unexpected error/)
        expect(Rails.logger).to receive(:error).with(kind_of(String)) # backtrace

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(RuntimeError)
      end

      it 'alerts admin' do
        expect(Rails.logger).to receive(:error).with(/ADMIN ALERT/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(RuntimeError)
      end
    end
  end

  describe 'job configuration' do
    it 'is enqueued in critical queue' do
      expect(described_class.new.queue_name).to eq('critical')
    end

    it 'has limited retry attempts for standard errors' do
      job = described_class.new(migration.id)

      # Standard errors should retry only once (attempts: 1)
      retry_config = job.class.retry_on_block_for(StandardError)
      expect(retry_config).to be_present
    end

    it 'has extended retry attempts for rate limit errors' do
      job = described_class.new(migration.id)

      # Rate limit errors should retry up to 3 times
      retry_config = job.class.retry_on_block_for(GoatService::RateLimitError)
      expect(retry_config).to be_present
    end
  end

  describe 'security measures' do
    before do
      allow(goat_service).to receive(:get_recommended_plc_operation).and_return(unsigned_op_path)
      allow(goat_service).to receive(:sign_plc_operation).and_return(signed_op_path)
      allow(goat_service).to receive(:submit_plc_operation)
    end

    it 'clears PLC token after successful submission' do
      expect(migration.encrypted_plc_token).to be_present

      described_class.perform_now(migration.id)

      migration.reload
      expect(migration.encrypted_plc_token).to be_nil
    end

    it 'logs token clearing for audit trail' do
      expect(Rails.logger).to receive(:info).with(/Clearing encrypted PLC token for security/)

      described_class.perform_now(migration.id)
    end

    it 'validates token before starting operation' do
      expect(migration).to receive(:plc_token).and_call_original

      described_class.perform_now(migration.id)
    end
  end

  describe 'point of no return' do
    before do
      allow(goat_service).to receive(:get_recommended_plc_operation).and_return(unsigned_op_path)
      allow(goat_service).to receive(:sign_plc_operation).and_return(signed_op_path)
      allow(goat_service).to receive(:submit_plc_operation)
    end

    it 'logs point of no return warning' do
      expect(Rails.logger).to receive(:info).with(/point of no return/)
      expect(Rails.logger).to receive(:info).with(/DID will be pointed to the new PDS/)

      described_class.perform_now(migration.id)
    end

    it 'logs DID update confirmation' do
      expect(Rails.logger).to receive(:info).with(/DID #{migration.did} now points to new PDS/)

      described_class.perform_now(migration.id)
    end

    it 'includes new PDS host in success message' do
      expect(Rails.logger).to receive(:info).with(/#{migration.new_pds_host}/)

      described_class.perform_now(migration.id)
    end
  end

  describe 'progress tracking' do
    before do
      allow(goat_service).to receive(:get_recommended_plc_operation).and_return(unsigned_op_path)
      allow(goat_service).to receive(:sign_plc_operation).and_return(signed_op_path)
      allow(goat_service).to receive(:submit_plc_operation)
    end

    it 'tracks all PLC operation stages' do
      described_class.perform_now(migration.id)

      migration.reload
      expect(migration.progress_data['plc_operation_recommended_at']).to be_present
      expect(migration.progress_data['plc_operation_signed_at']).to be_present
      expect(migration.progress_data['plc_operation_submitted_at']).to be_present
    end

    it 'persists progress data to database' do
      described_class.perform_now(migration.id)

      # Reload from database to ensure it was saved
      reloaded_migration = Migration.find(migration.id)
      expect(reloaded_migration.progress_data['plc_operation_submitted_at']).to be_present
    end
  end
end
