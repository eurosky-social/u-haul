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
    # The job refuses to touch PLC without an old-PDS session, and falls back to
    # generating a rotation key when one is missing. WaitForPlcTokenJob has
    # supplied both by the time this job runs.
    migration.set_old_pds_tokens!(access_token: 'old-access-token', refresh_token: 'old-refresh-token')
    migration.set_rotation_key('test-rotation-private-key')
    allow(GoatService).to receive(:new).with(migration).and_return(goat_service)

    # Examples below assert on individual log lines. Without a permissive
    # allowance underneath, expect(...).to receive(:info).with(/x/) constrains
    # *every* :info call, so the first unrelated line the job logs fails the
    # example for a reason unrelated to what it was testing.
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:debug)
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

      # A missing token is recoverable: the PLC directory has not been modified,
      # so the job records the failure and returns rather than raising, which
      # would let the rescue block relabel it as a CRITICAL failure.
      it 'marks migration as failed without raising' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('failed')
        expect(migration.last_error).to include('PLC token is missing')
      end

      it 'does not attempt PLC operation' do
        expect(goat_service).not_to receive(:get_recommended_plc_operation)

        described_class.perform_now(migration.id)
      end

      it 'logs error' do
        expect(Rails.logger).to receive(:error).with(/PLC token is missing/)

        described_class.perform_now(migration.id)
      end
    end

    context 'when PLC token is expired' do
      before do
        # Set token with 1 hour expiry, then travel past expiry
        migration.set_plc_token(plc_token)
        travel_to 2.hours.from_now
      end

      it 'marks migration as failed without raising' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('failed')
        expect(migration.last_error).to include('expired')
      end

      it 'does not submit PLC operation' do
        expect(goat_service).not_to receive(:submit_plc_operation)

        described_class.perform_now(migration.id)
      end
    end

    context 'when getting recommended PLC operation fails' do
      before do
        allow(goat_service).to receive(:get_recommended_plc_operation).and_raise(
          GoatService::NetworkError, 'Failed to get PLC operation'
        )
      end

      # Nothing has reached the PLC directory yet, so this is the recoverable
      # path: record it, mail the user to request a new token, no admin alert.
      it 'marks migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)

        migration.reload
        expect(migration.status).to eq('failed')
        expect(migration.last_error).to include('PLC update failed (before submission)')
      end

      it 'logs it as a pre-submission failure' do
        expect(Rails.logger).to receive(:error).with(/PLC update failed BEFORE submission/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)
      end

      it 'tells the user it is recoverable instead of alerting an admin' do
        expect(Rails.logger).to receive(:warn).with(/PLC UPDATE FAILED \(PRE-SUBMISSION\) - RECOVERABLE/)
        expect(Rails.logger).not_to receive(:error).with(/CRITICAL MIGRATION FAILURE - ADMIN ALERT/)

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

      # Still pre-submission: the user is mailed to request a new token rather
      # than an admin being paged.
      it 'alerts the user rather than an admin' do
        expect(Rails.logger).to receive(:warn).with(/PLC UPDATE FAILED \(PRE-SUBMISSION\) - RECOVERABLE/)

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

      # NOTE: the job classifies a failed submission as PRE-submission, because
      # progress_data['plc_operation_submitted_at'] is only written *after*
      # submit_plc_operation returns. If the directory accepted the operation and
      # the error happened on the way back, the DID has in fact been repointed and
      # this is the CRITICAL path being reported as recoverable. These examples
      # pin the behaviour as it stands - see the PR description.
      it 'currently treats a failed submission as pre-submission' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)

        migration.reload
        expect(migration.status).to eq('failed')
        expect(migration.last_error).to include('PLC update failed (before submission)')
      end

      it 'logs the failure' do
        expect(Rails.logger).to receive(:error).with(/PLC update failed BEFORE submission/)

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)
      end

      it 'does not currently raise an admin alert' do
        expect(Rails.logger).not_to receive(:error).with(/CRITICAL MIGRATION FAILURE - ADMIN ALERT/)

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

      # The job re-raises, but `retry_on GoatService::RateLimitError` catches it
      # and schedules a retry, so perform_now does not propagate it.
      it 'updates last_error with rate limit message' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.last_error).to include('Rate limit')
      end

      it 'logs warning about rate limit' do
        expect(Rails.logger).to receive(:warn).with(/Rate limit hit/)

        described_class.perform_now(migration.id)
      end

      it 'does not mark migration as failed' do
        described_class.perform_now(migration.id)

        migration.reload
        # Still pending_plc, not failed - it will be retried.
        expect(migration.status).to eq('pending_plc')
      end

      it 'schedules a retry rather than propagating the error' do
        expect {
          described_class.perform_now(migration.id)
        }.to have_enqueued_job(described_class)
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
        expect(Rails.logger).to receive(:error).with(/PLC update failed BEFORE submission/)
        expect(Rails.logger).to receive(:error).with(kind_of(String)) # backtrace

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(RuntimeError)
      end

      it 'alerts the user rather than an admin' do
        expect(Rails.logger).to receive(:warn).with(/PLC UPDATE FAILED \(PRE-SUBMISSION\) - RECOVERABLE/)

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

    # retry_on_block_for is not an ActiveJob API. Assert the behaviour the retry
    # configuration is meant to produce instead of reaching for internals.
    it 'gives up on a standard error rather than retrying indefinitely' do
      allow(goat_service).to receive(:get_recommended_plc_operation)
        .and_raise(GoatService::NetworkError, 'boom')

      expect {
        described_class.perform_now(migration.id)
      }.to raise_error(GoatService::NetworkError)
    end

    it 'retries a rate-limit error instead of failing the migration' do
      allow(goat_service).to receive(:get_recommended_plc_operation)
        .and_raise(GoatService::RateLimitError, 'Rate limit exceeded')

      expect {
        described_class.perform_now(migration.id)
      }.to have_enqueued_job(described_class)

      expect(migration.reload.status).to eq('pending_plc')
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

    # The job loads its own Migration instance via Migration.find, so stubbing
    # this one's reader proves nothing. Assert the decrypted token reaches the
    # step that needs it.
    it 'passes the decrypted token to the signing step' do
      expect(goat_service).to receive(:sign_plc_operation).with(unsigned_op_path, plc_token)

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
      # Both halves are the same single log line, so two expectations against it
      # could never both be satisfied.
      expect(Rails.logger).to receive(:info)
        .with(/point of no return - the DID will be pointed to the new PDS/)

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
