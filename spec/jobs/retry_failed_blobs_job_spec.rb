# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RetryFailedBlobsJob, type: :job do
  let(:storage_dir) { Rails.root.join('tmp', 'migrations', 'test_retry') }
  let(:migration) do
    Migration.create!(
      email: "test@example.com",
      did: "did:plc:retry#{SecureRandom.hex(4)}",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: :pending_plc,
      downloaded_data_path: storage_dir.to_s,
      progress_data: { 'failed_blobs' => %w[bafya bafyb], 'blobs_completed' => 8, 'blobs_total' => 10 }
    )
  end
  let(:goat_service) { instance_double(GoatService) }

  before do
    allow(GoatService).to receive(:new).with(migration).and_return(goat_service)
    # Blob passes label their stats with the version the target PDS reports,
    # so the double has to answer for it.
    allow(goat_service).to receive(:target_pds_version).and_return('0.5.29')
    allow(goat_service).to receive(:login_new_pds)
    allow_any_instance_of(described_class).to receive(:pause)
    FileUtils.mkdir_p(storage_dir.join('blobs'))
  end

  after do
    FileUtils.rm_rf(storage_dir) if Dir.exist?(storage_dir)
  end

  context 'when the blobs upload on retry' do
    before do
      File.write(storage_dir.join('blobs', 'bafya'), 'A')
      allow(goat_service).to receive(:download_blob).with('bafyb').and_return(storage_dir.join('dl-bafyb').to_s)
      File.write(storage_dir.join('dl-bafyb'), 'B')
      allow(goat_service).to receive(:upload_blob)
    end

    it 'prefers the backup-bundle copy, downloads the rest, and clears the list' do
      described_class.perform_now(migration.id, %w[bafya bafyb], 1)

      expect(goat_service).not_to have_received(:download_blob).with('bafya')
      expect(goat_service).to have_received(:upload_blob).with(storage_dir.join('blobs', 'bafya').to_s)
      expect(goat_service).to have_received(:upload_blob).with(storage_dir.join('dl-bafyb').to_s)

      progress = migration.reload.progress_data
      expect(progress['failed_blobs']).to eq([])
      expect(progress['blobs_completed']).to eq(10)
      expect(File.exist?(storage_dir.join('blobs', 'bafya'))).to be true
      expect(described_class).not_to have_been_enqueued
    end

    it 'sends no mail while the migration is not completed yet' do
      expect {
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)
      }.not_to have_enqueued_mail(MigrationMailer, :blobs_transfer_complete)
    end

    it 'sends the FINAL mail once when the migration is completed' do
      migration.update!(status: :completed)

      expect {
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)
      }.to have_enqueued_mail(MigrationMailer, :blobs_transfer_complete).once
      expect(migration.reload.progress_data['blobs_transfer_complete_mailed_at']).to be_present

      # a later manual retry with nothing left must not repeat it
      expect {
        described_class.perform_now(migration.id, [])
      }.not_to have_enqueued_mail(MigrationMailer, :blobs_transfer_complete)
    end
  end

  context 'when the blobs still fail' do
    before do
      allow(goat_service).to receive(:download_blob).and_return(storage_dir.join('dl').to_s)
      File.write(storage_dir.join('dl'), 'X')
      allow(goat_service).to receive(:upload_blob).and_raise(GoatService::NetworkError, '500 Internal Server Error')
    end

    it 'schedules the next background pass with the next delay' do
      described_class.perform_now(migration.id, %w[bafya bafyb], 1)

      expect(migration.reload.progress_data['failed_blobs']).to match_array(%w[bafya bafyb])
      expect(described_class).to have_been_enqueued.with(migration.id, match_array(%w[bafya bafyb]), 2)
    end

    it 'stops after the last background pass and records that it gave up' do
      described_class.perform_now(migration.id, %w[bafya bafyb], described_class::AUTO_RETRY_DELAYS.length + 1)

      expect(described_class).not_to have_been_enqueued
      expect(migration.reload.progress_data['blobs_auto_retry_exhausted_at']).to be_present
    end

    it 'sends the incomplete-transfer mail when it gives up on a completed migration' do
      migration.update!(status: :completed)

      expect {
        described_class.perform_now(migration.id, %w[bafya bafyb], described_class::AUTO_RETRY_DELAYS.length + 1)
      }.to have_enqueued_mail(MigrationMailer, :blobs_transfer_incomplete).once
    end

    it 'sends no incomplete mail while the migration is still in progress' do
      expect {
        described_class.perform_now(migration.id, %w[bafya bafyb], described_class::AUTO_RETRY_DELAYS.length + 1)
      }.not_to have_enqueued_mail(MigrationMailer, :blobs_transfer_incomplete)
    end

    it 'does not chain background passes after a manual retry' do
      described_class.perform_now(migration.id, %w[bafya bafyb])

      expect(described_class).not_to have_been_enqueued
    end
  end

  it 'does nothing for a failed or cancelled migration' do
    migration.update!(status: :failed, error_code: 'cancelled')

    expect(goat_service).not_to receive(:login_new_pds)
    described_class.perform_now(migration.id, %w[bafya bafyb], 1)
  end
end
