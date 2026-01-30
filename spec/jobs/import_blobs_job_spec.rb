# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportBlobsJob, type: :job do
  let(:migration) do
    Migration.create!(
      email: "test@example.com",
      did: "did:plc:test123abc",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: :pending_blobs
    )
  end

  let(:goat_service) { instance_double(GoatService) }
  let(:blob_cids) { ['bafyabc123', 'bafydef456', 'bafyghi789'] }

  before do
    migration.set_password('test_password_123')
    allow(GoatService).to receive(:new).with(migration).and_return(goat_service)
  end

  describe '#perform' do
    context 'when concurrency limit is not reached' do
      before do
        # Mock blob listing
        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => blob_cids, 'cursor' => nil }
        )

        # Mock blob downloads
        blob_cids.each_with_index do |cid, i|
          blob_path = Rails.root.join('tmp', 'goat', migration.did, 'blobs', cid)
          FileUtils.mkdir_p(File.dirname(blob_path))
          File.write(blob_path, "BLOB_DATA_#{i}")

          allow(goat_service).to receive(:download_blob).with(cid).and_return(blob_path)
          allow(goat_service).to receive(:upload_blob).with(blob_path).and_return(cid)
        end

        # Mock memory estimator
        allow(MemoryEstimatorService).to receive(:estimate).and_return(100)
      end

      it 'processes all blobs successfully' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_prefs')
      end

      it 'marks blobs_started_at timestamp' do
        freeze_time do
          described_class.perform_now(migration.id)

          migration.reload
          expect(migration.progress_data['blobs_started_at']).to eq(Time.current.iso8601)
        end
      end

      it 'marks blobs_completed_at timestamp' do
        freeze_time do
          described_class.perform_now(migration.id)

          migration.reload
          expect(migration.progress_data['blobs_completed_at']).to eq(Time.current.iso8601)
        end
      end

      it 'lists all blobs from old PDS' do
        expect(goat_service).to receive(:list_blobs).with(nil)
        described_class.perform_now(migration.id)
      end

      it 'downloads each blob' do
        blob_cids.each do |cid|
          expect(goat_service).to receive(:download_blob).with(cid)
        end

        described_class.perform_now(migration.id)
      end

      it 'uploads each blob to new PDS' do
        blob_cids.each do |cid|
          blob_path = Rails.root.join('tmp', 'goat', migration.did, 'blobs', cid)
          expect(goat_service).to receive(:upload_blob).with(blob_path)
        end

        described_class.perform_now(migration.id)
      end

      it 'estimates memory usage' do
        expect(MemoryEstimatorService).to receive(:estimate).and_return(100)
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.estimated_memory_mb).to eq(100)
      end

      it 'updates blob count' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data['blob_count']).to eq(blob_cids.length)
      end

      it 'advances to pending_prefs status' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_prefs')
      end

      it 'enqueues ImportPrefsJob' do
        expect {
          described_class.perform_now(migration.id)
        }.to have_enqueued_job(ImportPrefsJob)
      end
    end

    context 'when concurrency limit is reached' do
      before do
        # Create MAX_CONCURRENT_BLOB_MIGRATIONS migrations in pending_blobs status
        stub_const("#{described_class}::MAX_CONCURRENT_BLOB_MIGRATIONS", 2)

        2.times do |i|
          Migration.create!(
            email: "concurrent#{i}@example.com",
            did: "did:plc:concurrent#{i}",
            old_handle: "test#{i}.old.bsky.social",
            old_pds_host: "https://old.pds.example",
            new_handle: "test#{i}.new.bsky.social",
            new_pds_host: "https://new.pds.example",
            status: :pending_blobs
          )
        end
      end

      it 'does not process blobs' do
        expect(goat_service).not_to receive(:list_blobs)
        described_class.perform_now(migration.id)
      end

      it 're-enqueues job with delay' do
        expect {
          described_class.perform_now(migration.id)
        }.to have_enqueued_job(described_class).with(migration.id).at(30.seconds.from_now)
      end

      it 'does not advance migration status' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_blobs')
      end
    end

    context 'with paginated blob listing' do
      before do
        # First page
        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => ['blob1', 'blob2'], 'cursor' => 'page2' }
        )

        # Second page
        allow(goat_service).to receive(:list_blobs).with('page2').and_return(
          { 'cids' => ['blob3', 'blob4'], 'cursor' => nil }
        )

        # Mock blob operations
        ['blob1', 'blob2', 'blob3', 'blob4'].each do |cid|
          blob_path = Rails.root.join('tmp', 'goat', migration.did, 'blobs', cid)
          FileUtils.mkdir_p(File.dirname(blob_path))
          File.write(blob_path, "DATA")

          allow(goat_service).to receive(:download_blob).with(cid).and_return(blob_path)
          allow(goat_service).to receive(:upload_blob).with(blob_path).and_return(cid)
        end

        allow(MemoryEstimatorService).to receive(:estimate).and_return(100)
      end

      it 'fetches all pages of blobs' do
        expect(goat_service).to receive(:list_blobs).with(nil).ordered
        expect(goat_service).to receive(:list_blobs).with('page2').ordered

        described_class.perform_now(migration.id)
      end

      it 'processes all blobs from all pages' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data['blob_count']).to eq(4)
      end
    end

    context 'when blob transfer fails' do
      before do
        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => blob_cids, 'cursor' => nil }
        )

        allow(goat_service).to receive(:download_blob).and_raise(
          GoatService::NetworkError, 'Download failed'
        )

        allow(MemoryEstimatorService).to receive(:estimate).and_return(100)
      end

      it 'marks migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)

        migration.reload
        expect(migration.status).to eq('failed')
        expect(migration.last_error).to include('Blob import failed')
      end

      it 'logs error details' do
        expect(Rails.logger).to receive(:error).with(/Blob import failed/)
        expect(Rails.logger).to receive(:error).with(kind_of(String)) # backtrace

        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)
      end

      it 'increments retry count' do
        expect {
          described_class.perform_now(migration.id) rescue nil
        }.to change { migration.reload.retry_count }.by(1)
      end
    end

    context 'when rate limited' do
      before do
        allow(goat_service).to receive(:list_blobs).and_raise(
          GoatService::RateLimitError, 'Rate limit exceeded'
        )
      end

      it 'retries with polynomial backoff' do
        # The job is configured to retry 5 times for RateLimitError
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::RateLimitError)

        # Verify job is configured for retry
        job = described_class.new(migration.id)
        retry_config = job.class.retry_on_block_for(GoatService::RateLimitError)
        expect(retry_config).to be_present
      end
    end

    context 'with no blobs to transfer' do
      before do
        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => [], 'cursor' => nil }
        )

        allow(MemoryEstimatorService).to receive(:estimate).and_return(0)
      end

      it 'completes successfully' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_prefs')
      end

      it 'sets blob count to zero' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data['blob_count']).to eq(0)
      end

      it 'sets estimated memory to zero' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.estimated_memory_mb).to eq(0)
      end
    end

    context 'with large number of blobs' do
      let(:many_blobs) { 50.times.map { |i| "bafyblob#{i}" } }

      before do
        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => many_blobs, 'cursor' => nil }
        )

        # Mock blob operations for all blobs
        many_blobs.each do |cid|
          blob_path = Rails.root.join('tmp', 'goat', migration.did, 'blobs', cid)
          FileUtils.mkdir_p(File.dirname(blob_path))
          File.write(blob_path, "DATA")

          allow(goat_service).to receive(:download_blob).with(cid).and_return(blob_path)
          allow(goat_service).to receive(:upload_blob).with(blob_path).and_return(cid)
        end

        allow(MemoryEstimatorService).to receive(:estimate).and_return(1000)
      end

      it 'processes all blobs' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data['blob_count']).to eq(50)
      end

      it 'tracks progress throughout transfer' do
        described_class.perform_now(migration.id)

        migration.reload
        # Verify timestamps exist
        expect(migration.progress_data['blobs_started_at']).to be_present
        expect(migration.progress_data['blobs_completed_at']).to be_present
      end
    end
  end

  describe 'job configuration' do
    it 'is enqueued in migrations queue' do
      expect(described_class.new.queue_name).to eq('migrations')
    end

    it 'has retry configuration' do
      job = described_class.new(migration.id)

      # Check that retry_on is configured
      expect(described_class.retry_on_block_for(StandardError)).to be_present
      expect(described_class.retry_on_block_for(GoatService::RateLimitError)).to be_present
    end
  end

  describe 'concurrency control' do
    it 'enforces maximum concurrent blob migrations' do
      expect(described_class::MAX_CONCURRENT_BLOB_MIGRATIONS).to eq(15)
    end

    it 'uses appropriate requeue delay' do
      expect(described_class::REQUEUE_DELAY).to eq(30.seconds)
    end
  end

  describe 'memory management' do
    it 'defines progress update interval' do
      expect(described_class::PROGRESS_UPDATE_INTERVAL).to eq(10)
    end

    it 'defines garbage collection interval' do
      expect(described_class::GC_INTERVAL).to eq(50)
    end

    it 'defines parallel blob transfer count' do
      expect(described_class::PARALLEL_BLOB_TRANSFERS).to eq(10)
    end
  end
end
