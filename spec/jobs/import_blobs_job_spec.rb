# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportBlobsJob, type: :job do
  # The job hands blob transfers to a pool of PARALLEL_BLOBS threads, releasing
  # the main thread's DB connection first so it doesn't idle on a pooled
  # connection while waiting on joins. Transactional fixtures pin the example's
  # open transaction to that same connection, so the two cannot coexist:
  # releasing it makes teardown try to check in a connection owned by a dead
  # worker thread, which raises intermittently depending on interleaving.
  # Stubbing the release out instead just starves the pool - PARALLEL_BLOBS is 5
  # and so is the pool - and every checkout waits out its 5s timeout.
  self.use_transactional_tests = false

  after { Migration.delete_all }

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
    # The job authenticates against the target PDS before uploading anything;
    # without this the double rejects the call and every example fails there.
    allow(goat_service).to receive(:login_new_pds)

    # Post-import reconciliation asks the PDS how many blobs it expected against
    # how many arrived. Matching counts short-circuit it, so examples exercise
    # the import path rather than the recovery path; contexts that care about
    # reconciliation override this.
    allow(goat_service).to receive(:get_account_status)
      .and_return({ 'expectedBlobs' => 0, 'importedBlobs' => 0 })
    allow(goat_service).to receive(:collect_all_missing_blobs).and_return([])

    # Per-blob retries back off with sleep(2**attempt); without this the failure
    # examples spend ~14s each waiting out real backoff.
    allow_any_instance_of(described_class).to receive(:sleep)


  end

  describe '#perform' do
    context 'successful blob transfer' do
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

    context 'with many concurrent migrations (no global limit)' do
      before do
        30.times do |i|
          Migration.create!(
            email: "concurrent#{i}@example.com",
            did: "did:plc:concurrent#{i}",
            old_handle: "test#{i}.old.bsky.social",
            old_pds_host: "https://old.pds.example",
            new_handle: "test#{i}.new.bsky.social",
            new_pds_host: "https://new.pds.example",
            status: [:pending_download, :pending_blobs].sample
          )
        end
      end

      it 'proceeds immediately without blocking' do
        expect(goat_service).to receive(:list_blobs).and_return({ 'cids' => ['blob1'], 'cursor' => nil })
        expect(goat_service).to receive(:login_new_pds)
        expect(goat_service).to receive(:download_blob).with('blob1').and_return('/tmp/blob1')
        expect(goat_service).to receive(:upload_blob).with('/tmp/blob1')
        allow(goat_service).to receive(:get_account_status).and_return({ 'expectedBlobs' => 1, 'importedBlobs' => 1 })
        allow(File).to receive(:size).and_return(1024)
        allow(FileUtils).to receive(:rm_f)

        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_prefs')
      end

      it 'does not set queued state' do
        expect(goat_service).to receive(:list_blobs).and_return({ 'cids' => ['blob1'], 'cursor' => nil })
        expect(goat_service).to receive(:login_new_pds)
        expect(goat_service).to receive(:download_blob).with('blob1').and_return('/tmp/blob1')
        expect(goat_service).to receive(:upload_blob).with('/tmp/blob1')
        allow(goat_service).to receive(:get_account_status).and_return({ 'expectedBlobs' => 1, 'importedBlobs' => 1 })
        allow(File).to receive(:size).and_return(1024)
        allow(FileUtils).to receive(:rm_f)

        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data).not_to have_key('queued')
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

      end

      # A blob that will not transfer is not treated as fatal: the job records
      # the CID, writes a manifest, and carries on. RetryFailedBlobsJob exists to
      # pick them up later.
      #
      # NOTE: that holds even when *every* blob fails, as here. The migration
      # still advances to pending_prefs and the user is moved along with none of
      # their media. Reconciliation is stubbed out in these examples, so it is
      # the only thing that would notice - see the PR description.
      it 'records the failed blobs rather than failing the migration' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data['failed_blobs']).to match_array(blob_cids)
      end

      # ImportBlobsJob logs through ActiveJob's `logger`, which is not the same
      # object as Rails.logger - expectations set on Rails.logger silently never
      # match. Assert against the job's own logger instead.
      it 'logs the transfer failures' do
        job_logger = instance_spy(ActiveSupport::Logger)
        allow_any_instance_of(described_class).to receive(:logger).and_return(job_logger)

        described_class.perform_now(migration.id)

        expect(job_logger).to have_received(:warn).with(/Failed to transfer 3 blobs/)
      end

      it 'still advances to the next stage' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_prefs')
      end
    end

    context 'when rate limited' do
      before do
        allow(goat_service).to receive(:list_blobs).and_raise(
          GoatService::RateLimitError, 'Rate limit exceeded'
        )
      end

      # retry_on GoatService::RateLimitError catches the error and schedules a
      # retry rather than letting it propagate.
      it 'retries rather than propagating the rate limit' do
        expect {
          described_class.perform_now(migration.id)
        }.to have_enqueued_job(described_class)
      end
    end

    context 'with no blobs to transfer' do
      before do
        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => [], 'cursor' => nil }
        )

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

    # retry_on_block_for is not an ActiveJob API. Assert the behaviour the retry
    # configuration is meant to produce instead of reaching for internals.
    it 'retries instead of surfacing a failure to the caller' do
      allow(goat_service).to receive(:list_blobs)
        .and_raise(GoatService::NetworkError, 'boom')

      expect {
        described_class.perform_now(migration.id)
      }.to have_enqueued_job(described_class)
    end
  end

  describe 'constants' do
    it 'limits parallel blob transfers to 5' do
      expect(described_class::PARALLEL_BLOBS).to eq(5)
    end

    it 'defines progress update interval' do
      expect(described_class::PROGRESS_UPDATE_INTERVAL).to eq(10)
    end
  end
end
