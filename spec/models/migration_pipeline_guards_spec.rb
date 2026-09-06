# frozen_string_literal: true

require 'rails_helper'

# Guards that keep the job pipeline from restarting, resurrecting or clobbering
# a migration: email verification starts the pipeline exactly once, status
# advances are conditional, and progress writes are atomic merges.
RSpec.describe Migration, 'pipeline guards' do
  let(:attrs) do
    {
      email: "test@example.com",
      did: "did:plc:test#{SecureRandom.hex(6)}",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example"
    }
  end

  describe '#verify_email!' do
    it 'starts the pipeline for a migration that has not run yet' do
      migration = described_class.create!(attrs)

      expect(DownloadAllDataJob).to receive(:perform_later).with(migration.id)
      expect(migration.verify_email!(migration.email_verification_token)).to be true
      expect(migration.reload.status).to eq('pending_download')
      expect(migration.email_verified_at).to be_present
    end

    it 'restarts from the beginning a migration that was advanced without verification' do
      migration = described_class.create!(attrs.merge(status: :pending_plc))

      expect(DownloadAllDataJob).to receive(:perform_later).with(migration.id)
      expect(migration.verify_email!(migration.email_verification_token)).to be true
      expect(migration.reload.status).to eq('pending_download')
      expect(migration.email_verified_at).to be_present
    end

    it 'restarts a migration that failed before verification' do
      migration = described_class.create!(attrs.merge(status: :failed, error_code: 'account_exists', last_error: 'Orphaned'))

      expect(DownloadAllDataJob).to receive(:perform_later).with(migration.id)
      expect(migration.verify_email!(migration.email_verification_token)).to be true
      expect(migration.reload.status).to eq('pending_download')
      expect(migration.error_code).to be_nil
      expect(migration.last_error).to be_nil
    end

    it 'never restarts after the PLC operation was submitted' do
      migration = described_class.create!(attrs.merge(status: :pending_activation))
      migration.update!(progress_data: { 'plc_operation_submitted_at' => Time.current.iso8601 })

      expect(DownloadAllDataJob).not_to receive(:perform_later)
      expect(CreateAccountJob).not_to receive(:perform_later)
      expect(migration.verify_email!(migration.email_verification_token)).to be true
      expect(migration.reload.status).to eq('pending_activation')
      expect(migration.email_verified_at).to be_present
    end

    it 'rejects a wrong code' do
      migration = described_class.create!(attrs)

      expect(DownloadAllDataJob).not_to receive(:perform_later)
      expect(migration.verify_email!('NOPE-00')).to be false
      expect(migration.reload.email_verified_at).to be_nil
    end
  end

  describe '#advance_with_job!' do
    it 'raises Aborted and leaves the row alone when it was cancelled underneath' do
      migration = described_class.create!(attrs.merge(status: :pending_blobs))
      described_class.where(id: migration.id).update_all(status: 'failed', error_code: 'cancelled')

      expect(ImportPrefsJob).not_to receive(:perform_later)
      expect { migration.advance_to_pending_prefs! }.to raise_error(Migration::Aborted)
      expect(migration.reload.status).to eq('failed')
      expect(migration.error_code).to eq('cancelled')
    end

    it 'advances and enqueues when the row is unchanged' do
      migration = described_class.create!(attrs.merge(status: :pending_blobs))

      expect(ImportPrefsJob).to receive(:perform_later).with(migration.id)
      migration.advance_to_pending_prefs!
      expect(migration.reload.status).to eq('pending_prefs')
    end

    it 'reverts the status when the enqueue fails' do
      migration = described_class.create!(attrs.merge(status: :pending_blobs))
      allow(ImportPrefsJob).to receive(:perform_later).and_raise(Redis::CannotConnectError, 'redis down')

      expect { migration.advance_to_pending_prefs! }.to raise_error(Redis::CannotConnectError)
      expect(migration.reload.status).to eq('pending_blobs')
    end
  end

  describe '#terminal_in_db?' do
    it 'reflects the database, not the in-memory object' do
      migration = described_class.create!(attrs.merge(status: :pending_blobs))
      expect(migration.terminal_in_db?).to be false

      described_class.where(id: migration.id).update_all(status: 'failed')
      expect(migration.status).to eq('pending_blobs')
      expect(migration.terminal_in_db?).to be true
    end

    it 'does not treat a row it cannot see as terminal' do
      migration = described_class.create!(attrs.merge(status: :pending_blobs))
      described_class.where(id: migration.id).delete_all

      expect(migration.terminal_in_db?).to be false
    end
  end

  describe '#merge_progress!' do
    it 'keeps keys written by other processes and updates the in-memory copy' do
      migration = described_class.create!(attrs.merge(status: :pending_blobs))
      described_class.where(id: migration.id)
                     .update_all("progress_data = '{\"cancelled_at\": \"2026-09-05T00:00:00Z\"}'::jsonb")

      migration.merge_progress!('blobs_completed' => 3, 'blobs_total' => 10)

      expect(migration.progress_data).to include('blobs_completed' => 3, 'blobs_total' => 10)
      expect(migration.reload.progress_data).to include(
        'cancelled_at' => '2026-09-05T00:00:00Z',
        'blobs_completed' => 3,
        'blobs_total' => 10
      )
    end
  end

  describe '#blob_upload_percentage' do
    it 'reads the upload job keys as a fallback' do
      migration = described_class.create!(attrs.merge(status: :pending_blobs))
      migration.progress_data = { 'blobs_uploaded' => 5, 'blobs_total' => 10 }

      # 40% base (backup bundle) + half of the 30% blob range
      expect(migration.progress_percentage).to eq(55)
    end
  end
end
