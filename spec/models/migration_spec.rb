# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Migration, type: :model do
  let(:valid_attributes) do
    {
      email: "test@example.com",
      did: "did:plc:test123abc",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example"
    }
  end

  describe 'validations' do
    it 'validates presence of did' do
      migration = described_class.new(valid_attributes.merge(did: nil))
      expect(migration).not_to be_valid
      expect(migration.errors[:did]).to include("can't be blank")
    end

    it 'validates presence of email' do
      migration = described_class.new(valid_attributes.merge(email: nil))
      expect(migration).not_to be_valid
      expect(migration.errors[:email]).to include("can't be blank")
    end

    it 'validates presence of old_pds_host' do
      migration = described_class.new(valid_attributes.merge(old_pds_host: nil))
      expect(migration).not_to be_valid
      expect(migration.errors[:old_pds_host]).to include("can't be blank")
    end

    it 'validates presence of new_pds_host' do
      migration = described_class.new(valid_attributes.merge(new_pds_host: nil))
      expect(migration).not_to be_valid
      expect(migration.errors[:new_pds_host]).to include("can't be blank")
    end

    it 'validates presence of old_handle' do
      migration = described_class.new(valid_attributes.merge(old_handle: nil))
      expect(migration).not_to be_valid
      expect(migration.errors[:old_handle]).to include("can't be blank")
    end

    it 'validates presence of new_handle' do
      migration = described_class.new(valid_attributes.merge(new_handle: nil))
      expect(migration).not_to be_valid
      expect(migration.errors[:new_handle]).to include("can't be blank")
    end

    describe 'DID validation' do
      it 'validates DID format' do
        migration = described_class.new(valid_attributes.merge(did: 'invalid_did'))
        expect(migration).not_to be_valid
        expect(migration.errors[:did]).to include(/is invalid/)
      end

      it 'accepts valid DID formats' do
        valid_dids = [
          'did:plc:abc123',
          'did:web:example.com',
          'did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK'
        ]

        valid_dids.each do |did|
          migration = described_class.new(valid_attributes.merge(did: did))
          expect(migration).to be_valid
        end
      end

      it 'validates DID uniqueness' do
        described_class.create!(valid_attributes)
        duplicate = described_class.new(valid_attributes)
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:did]).to include(/has already been taken/)
      end
    end

    describe 'email validation' do
      it 'validates email format' do
        invalid_emails = ['not_an_email', 'missing@domain', '@example.com']

        invalid_emails.each do |email|
          migration = described_class.new(valid_attributes.merge(email: email))
          expect(migration).not_to be_valid
          expect(migration.errors[:email]).to be_present
        end
      end

      it 'accepts valid email formats' do
        valid_emails = ['user@example.com', 'test+tag@sub.domain.com', 'name.surname@co.uk']

        valid_emails.each do |email|
          migration = described_class.new(valid_attributes.merge(email: email))
          expect(migration).to be_valid
        end
      end
    end

    describe 'token validation' do
      it 'validates token format' do
        migration = described_class.create!(valid_attributes)
        expect(migration.token).to match(/\AEURO-[A-Z0-9]{8}\z/)
      end

      it 'validates token uniqueness' do
        first = described_class.create!(valid_attributes)
        second = described_class.new(valid_attributes.merge(did: 'did:plc:different', token: first.token))
        expect(second).not_to be_valid
        expect(second.errors[:token]).to include(/has already been taken/)
      end
    end

    describe 'retry_count validation' do
      it 'must be non-negative integer' do
        migration = described_class.new(valid_attributes.merge(retry_count: -1))
        expect(migration).not_to be_valid
        expect(migration.errors[:retry_count]).to be_present
      end

      it 'accepts zero and positive integers' do
        [0, 1, 5, 10].each do |count|
          migration = described_class.new(valid_attributes.merge(retry_count: count))
          expect(migration).to be_valid
        end
      end
    end

    describe 'estimated_memory_mb validation' do
      it 'must be non-negative integer' do
        migration = described_class.new(valid_attributes.merge(estimated_memory_mb: -100))
        expect(migration).not_to be_valid
      end

      it 'accepts zero and positive integers' do
        [0, 100, 1000].each do |mb|
          migration = described_class.new(valid_attributes.merge(estimated_memory_mb: mb))
          expect(migration).to be_valid
        end
      end
    end
  end

  describe 'callbacks' do
    describe 'before_validation' do
      it 'generates token on create' do
        migration = described_class.new(valid_attributes)
        migration.valid?
        expect(migration.token).to match(/\AEURO-[A-Z0-9]{8}\z/)
      end

      it 'does not regenerate token on update' do
        migration = described_class.create!(valid_attributes)
        original_token = migration.token
        migration.update!(email: 'new@example.com')
        expect(migration.token).to eq(original_token)
      end

      it 'normalizes PDS host URLs' do
        migration = described_class.create!(
          valid_attributes.merge(
            old_pds_host: 'https://old.pds.example/',
            new_pds_host: 'https://new.pds.example/'
          )
        )
        expect(migration.old_pds_host).to eq('https://old.pds.example')
        expect(migration.new_pds_host).to eq('https://new.pds.example')
      end
    end

    describe 'after_create' do
      it 'schedules first job' do
        expect {
          described_class.create!(valid_attributes)
        }.to have_enqueued_job
      end
    end
  end

  describe 'state machine transitions' do
    let(:migration) { described_class.create!(valid_attributes) }

    describe '#advance_to_pending_repo!' do
      it 'updates status to pending_repo' do
        expect {
          migration.advance_to_pending_repo!
        }.to change(migration, :status).to('pending_repo')
      end

      it 'enqueues ImportRepoJob' do
        expect {
          migration.advance_to_pending_repo!
        }.to have_enqueued_job(ImportRepoJob)
      end
    end

    describe '#advance_to_pending_blobs!' do
      it 'updates status to pending_blobs' do
        expect {
          migration.advance_to_pending_blobs!
        }.to change(migration, :status).to('pending_blobs')
      end

      it 'enqueues ImportBlobsJob' do
        expect {
          migration.advance_to_pending_blobs!
        }.to have_enqueued_job(ImportBlobsJob)
      end
    end

    describe '#advance_to_pending_prefs!' do
      it 'updates status to pending_prefs' do
        expect {
          migration.advance_to_pending_prefs!
        }.to change(migration, :status).to('pending_prefs')
      end

      it 'enqueues ImportPrefsJob' do
        expect {
          migration.advance_to_pending_prefs!
        }.to have_enqueued_job(ImportPrefsJob)
      end
    end

    describe '#advance_to_pending_plc!' do
      it 'updates status to pending_plc' do
        expect {
          migration.advance_to_pending_plc!
        }.to change(migration, :status).to('pending_plc')
      end

      it 'enqueues WaitForPlcTokenJob' do
        expect {
          migration.advance_to_pending_plc!
        }.to have_enqueued_job(WaitForPlcTokenJob)
      end
    end

    describe '#advance_to_pending_activation!' do
      it 'updates status to pending_activation' do
        expect {
          migration.advance_to_pending_activation!
        }.to change(migration, :status).to('pending_activation')
      end

      it 'enqueues ActivateAccountJob' do
        expect {
          migration.advance_to_pending_activation!
        }.to have_enqueued_job(ActivateAccountJob)
      end
    end

    describe '#mark_complete!' do
      before { migration.update!(status: :pending_activation) }

      it 'updates status to completed' do
        expect {
          migration.mark_complete!
        }.to change(migration, :status).to('completed')
      end

      it 'clears last_error' do
        migration.update!(last_error: 'Some error')
        migration.mark_complete!
        expect(migration.last_error).to be_nil
      end
    end

    describe '#mark_failed!' do
      let(:error) { StandardError.new('Test error') }

      it 'updates status to failed' do
        expect {
          migration.mark_failed!(error)
        }.to change(migration, :status).to('failed')
      end

      it 'sets last_error message' do
        migration.mark_failed!(error)
        expect(migration.last_error).to eq('Test error')
      end

      it 'increments retry_count' do
        expect {
          migration.mark_failed!(error)
        }.to change(migration, :retry_count).by(1)
      end
    end
  end

  describe 'progress tracking' do
    let(:migration) { described_class.create!(valid_attributes) }

    describe '#update_blob_progress!' do
      it 'tracks blob upload progress' do
        migration.update_blob_progress!(cid: 'bafyabc123', size: 1000, uploaded: 500)

        expect(migration.progress_data['blobs']).to be_present
        expect(migration.progress_data['blobs']['bafyabc123']).to include(
          'size' => 1000,
          'uploaded' => 500
        )
      end

      it 'updates timestamp' do
        freeze_time do
          migration.update_blob_progress!(cid: 'bafyabc123', size: 1000, uploaded: 500)

          expect(migration.progress_data['blobs']['bafyabc123']['updated_at']).to eq(Time.current.iso8601)
        end
      end

      it 'persists changes to database' do
        migration.update_blob_progress!(cid: 'bafyabc123', size: 1000, uploaded: 500)

        migration.reload
        expect(migration.progress_data['blobs']['bafyabc123']).to be_present
      end
    end

    describe '#progress_percentage' do
      it 'returns 0% for pending_account status' do
        migration.update!(status: :pending_account)
        expect(migration.progress_percentage).to eq(0)
      end

      it 'returns 20% for pending_repo status' do
        migration.update!(status: :pending_repo)
        expect(migration.progress_percentage).to eq(20)
      end

      it 'returns 70% for pending_prefs status' do
        migration.update!(status: :pending_prefs)
        expect(migration.progress_percentage).to eq(70)
      end

      it 'returns 80% for pending_plc status' do
        migration.update!(status: :pending_plc)
        expect(migration.progress_percentage).to eq(80)
      end

      it 'returns 90% for pending_activation status' do
        migration.update!(status: :pending_activation)
        expect(migration.progress_percentage).to eq(90)
      end

      it 'returns 100% for completed status' do
        migration.update!(status: :completed)
        expect(migration.progress_percentage).to eq(100)
      end

      it 'returns 0% for failed status' do
        migration.update!(status: :failed)
        expect(migration.progress_percentage).to eq(0)
      end

      describe 'blob upload percentage' do
        before { migration.update!(status: :pending_blobs) }

        it 'calculates percentage based on blob progress' do
          migration.progress_data = {
            'total_blobs' => 10,
            'uploaded_blobs' => 5
          }
          migration.save!

          # Should be between 20% (start of blobs) and 70% (end of blobs)
          percentage = migration.progress_percentage
          expect(percentage).to be >= 20
          expect(percentage).to be < 70
        end
      end
    end

    describe '#estimated_time_remaining' do
      before do
        migration.update!(status: :pending_blobs)
        migration.progress_data = {
          'blobs' => {
            'blob1' => {
              'size' => 1000,
              'uploaded' => 1000,
              'updated_at' => 1.minute.ago.iso8601
            },
            'blob2' => {
              'size' => 2000,
              'uploaded' => 1000,
              'updated_at' => Time.current.iso8601
            }
          }
        }
        migration.save!
      end

      it 'estimates time remaining based on upload rate' do
        estimate = migration.estimated_time_remaining
        expect(estimate).to be_a(Integer)
        expect(estimate).to be > 0
      end

      it 'returns nil if no blob progress' do
        migration.progress_data = {}
        migration.save!
        expect(migration.estimated_time_remaining).to be_nil
      end

      it 'returns nil if not in pending_blobs status' do
        migration.update!(status: :pending_prefs)
        expect(migration.estimated_time_remaining).to be_nil
      end
    end
  end

  describe 'credential management' do
    let(:migration) { described_class.create!(valid_attributes) }
    let(:password) { 'test_password_123' }
    let(:plc_token) { 'plc_token_abc' }

    describe '#set_password' do
      it 'encrypts and stores password' do
        migration.set_password(password)
        expect(migration.encrypted_password).to be_present
        expect(migration.encrypted_password).not_to eq(password)
      end

      it 'sets credentials expiry to 48 hours' do
        freeze_time do
          migration.set_password(password)
          expect(migration.credentials_expires_at).to be_within(1.second).of(48.hours.from_now)
        end
      end
    end

    describe '#set_plc_token' do
      it 'encrypts and stores PLC token' do
        migration.set_plc_token(plc_token)
        expect(migration.encrypted_plc_token).to be_present
        expect(migration.encrypted_plc_token).not_to eq(plc_token)
      end

      it 'sets credentials expiry to 1 hour' do
        freeze_time do
          migration.set_plc_token(plc_token)
          expect(migration.credentials_expires_at).to be_within(1.second).of(1.hour.from_now)
        end
      end
    end

    describe '#password' do
      before { migration.set_password(password) }

      it 'returns decrypted password when not expired' do
        expect(migration.password).to eq(password)
      end

      it 'returns nil when credentials expired' do
        travel_to 49.hours.from_now do
          expect(migration.password).to be_nil
        end
      end
    end

    describe '#plc_token' do
      before { migration.set_plc_token(plc_token) }

      it 'returns decrypted token when not expired' do
        expect(migration.plc_token).to eq(plc_token)
      end

      it 'returns nil when credentials expired' do
        travel_to 2.hours.from_now do
          expect(migration.plc_token).to be_nil
        end
      end
    end

    describe '#credentials_expired?' do
      it 'returns false when credentials are fresh' do
        migration.set_password(password)
        expect(migration.credentials_expired?).to be false
      end

      it 'returns true when credentials have expired' do
        migration.set_password(password)
        travel_to 49.hours.from_now do
          expect(migration.credentials_expired?).to be true
        end
      end

      it 'returns true when credentials_expires_at is nil' do
        migration.update!(credentials_expires_at: nil)
        expect(migration.credentials_expired?).to be true
      end
    end

    describe '#clear_credentials!' do
      before do
        migration.set_password(password)
        migration.set_plc_token(plc_token)
      end

      it 'clears encrypted password' do
        migration.clear_credentials!
        expect(migration.encrypted_password).to be_nil
      end

      it 'clears encrypted PLC token' do
        migration.clear_credentials!
        expect(migration.encrypted_plc_token).to be_nil
      end

      it 'clears credentials expiry' do
        migration.clear_credentials!
        expect(migration.credentials_expires_at).to be_nil
      end

      it 'logs credential clearing' do
        expect(Rails.logger).to receive(:info).with(/Cleared encrypted credentials/)
        migration.clear_credentials!
      end
    end
  end

  describe 'scopes' do
    before do
      described_class.create!(valid_attributes.merge(status: :completed, did: 'did:plc:completed'))
      described_class.create!(valid_attributes.merge(status: :failed, did: 'did:plc:failed'))
      described_class.create!(valid_attributes.merge(status: :pending_repo, did: 'did:plc:active1'))
      described_class.create!(valid_attributes.merge(status: :pending_plc, did: 'did:plc:plc1'))
      described_class.create!(valid_attributes.merge(status: :pending_blobs, did: 'did:plc:active2'))
    end

    describe '.active' do
      it 'returns migrations that are not completed or failed' do
        active = described_class.active
        expect(active.count).to eq(3)
        expect(active.pluck(:status)).not_to include('completed', 'failed')
      end
    end

    describe '.pending_plc' do
      it 'returns only migrations waiting for PLC token' do
        pending = described_class.pending_plc
        expect(pending.count).to eq(1)
        expect(pending.first.status).to eq('pending_plc')
      end
    end

    describe '.in_progress' do
      it 'returns migrations in processing stages' do
        in_progress = described_class.in_progress
        expect(in_progress.count).to eq(2)
        statuses = in_progress.pluck(:status)
        expect(statuses).to include('pending_repo', 'pending_blobs')
      end
    end

    describe '.by_memory' do
      before do
        described_class.first.update!(estimated_memory_mb: 500)
        described_class.second.update!(estimated_memory_mb: 1000)
        described_class.third.update!(estimated_memory_mb: 200)
      end

      it 'orders migrations by memory usage descending' do
        ordered = described_class.by_memory
        memory_values = ordered.pluck(:estimated_memory_mb).compact
        expect(memory_values).to eq(memory_values.sort.reverse)
      end
    end

    describe '.recent' do
      it 'orders migrations by creation date descending' do
        recent = described_class.recent
        created_at_values = recent.pluck(:created_at)
        expect(created_at_values).to eq(created_at_values.sort.reverse)
      end
    end
  end

  describe 'encryption' do
    let(:migration) { described_class.create!(valid_attributes) }

    it 'encrypts password field' do
      migration.set_password('secret_password')

      # Check that the value in the database is encrypted (not plaintext)
      raw_value = migration.read_attribute_before_type_cast(:encrypted_password)
      expect(raw_value).not_to eq('secret_password')
      expect(raw_value).to be_present
    end

    it 'decrypts password field' do
      migration.set_password('secret_password')
      migration.reload
      expect(migration.password).to eq('secret_password')
    end

    it 'encrypts PLC token field' do
      migration.set_plc_token('plc_secret_token')

      raw_value = migration.read_attribute_before_type_cast(:encrypted_plc_token)
      expect(raw_value).not_to eq('plc_secret_token')
      expect(raw_value).to be_present
    end

    it 'decrypts PLC token field' do
      migration.set_plc_token('plc_secret_token')
      migration.reload
      expect(migration.plc_token).to eq('plc_secret_token')
    end
  end
end
