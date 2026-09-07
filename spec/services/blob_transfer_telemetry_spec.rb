# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BlobTransferTelemetry do
  let(:migration) { create_test_migration(status: :pending_blobs) }
  let(:goat) { instance_double(GoatService, target_pds_version: '0.5.29') }

  def collect(pass: described_class::PASS_PARALLEL, &block)
    described_class.record(migration, job_name: 'ImportBlobsJob', pass: pass, goat: goat, &block)
    BlobTransferStat.last
  end

  # Deliberately not a GoatService error: telemetry must cope with whatever the
  # transfer code raises, not just the classified cases.
  def raise_upload(error)
    ->(_telemetry) { raise error }
  end

  describe 'recording a pass' do
    it 'writes one row describing the pass' do
      stat = collect do |telemetry|
        telemetry.attempt(cid: 'bafy1', bytes: 1_000) { :uploaded }
        telemetry.attempt(cid: 'bafy2', bytes: 3_000) { :uploaded }
      end

      expect(stat).to have_attributes(
        migration_id: migration.id,
        job_name: 'ImportBlobsJob',
        pass: 'parallel',
        target_host: migration.new_pds_host,
        source_host: migration.old_pds_host,
        target_pds_version: '0.5.29',
        blobs_attempted: 2,
        blobs_succeeded: 2,
        blobs_failed: 0,
        upload_attempts: 2,
        bytes_transferred: 4_000
      )
      expect(stat.outcome_counts).to eq('upload.ok' => 2)
    end

    it 'does not write a row for a pass that had nothing to do' do
      expect { collect { |_telemetry| } }.not_to change(BlobTransferStat, :count)
    end

    it 'records the pass even when the block raises part-way through' do
      expect do
        described_class.record(migration, job_name: 'ImportBlobsJob',
                                          pass: described_class::PASS_PARALLEL, goat: goat) do |telemetry|
          telemetry.attempt(cid: 'bafy1', bytes: 10) { :uploaded }
          raise 'pool exploded'
        end
      end.to raise_error('pool exploded')

      expect(BlobTransferStat.last.blobs_succeeded).to eq(1)
    end
  end

  describe 'classifying failures' do
    it 'files an HTTP error under its status code' do
      error = GoatService::NetworkError.new('Failed to upload blob: 500 Internal Server Error',
                                            http_status: 500, phase: :upload)
      stat = collect do |telemetry|
        telemetry.attempt(cid: 'bafy1', bytes: 10) { raise error } rescue nil
      end

      expect(stat.outcome_counts).to eq('upload.http_500' => 1)
      expect(stat.blobs_failed).to eq(1)
    end

    it 'separates a stalled upload from an HTTP error' do
      stat = collect do |telemetry|
        telemetry.attempt(cid: 'bafy1', bytes: 10) do
          raise GoatService::TimeoutError.new('stalled', phase: :upload)
        end
      rescue GoatService::TimeoutError
        nil
      end

      expect(stat.outcome_counts).to eq('upload.timeout' => 1)
    end

    it 'files rate limiting under its own bucket rather than http_429' do
      stat = collect do |telemetry|
        telemetry.attempt(cid: 'bafy1', bytes: 10) do
          raise GoatService::RateLimitError.new('slow down', retry_after: 30, http_status: 429)
        end
      rescue GoatService::RateLimitError
        nil
      end

      expect(stat.outcome_counts).to eq('upload.rate_limited' => 1)
    end

    it 'falls back to a generic bucket for an unclassified error' do
      stat = collect do |telemetry|
        telemetry.attempt(cid: 'bafy1', bytes: 10) { raise IOError, 'socket gone' }
      rescue IOError
        nil
      end

      expect(stat.outcome_counts).to eq('upload.error' => 1)
      expect(stat.failure_samples.first).to include('error_class' => 'IOError', 'cid' => 'bafy1')
    end

    it 'keeps the failure sample list bounded' do
      stat = collect do |telemetry|
        (described_class::MAX_FAILURE_SAMPLES + 10).times do |i|
          telemetry.attempt(cid: "bafy#{i}", bytes: 10) { raise IOError, 'nope' } rescue nil
        end
      end

      expect(stat.failure_samples.length).to eq(described_class::MAX_FAILURE_SAMPLES)
      expect(stat.blobs_failed).to eq(described_class::MAX_FAILURE_SAMPLES + 10)
    end
  end

  describe 'counting retries' do
    it 'counts every attempt but resolves the blob to one outcome' do
      stat = collect do |telemetry|
        # Two failures then a success, the way the jobs' retry helpers behave.
        2.times do
          telemetry.attempt(cid: 'bafy1', bytes: 500) { raise IOError, 'nope' } rescue nil
        end
        telemetry.attempt(cid: 'bafy1', bytes: 500) { :uploaded }
      end

      expect(stat).to have_attributes(blobs_attempted: 1, blobs_succeeded: 1,
                                      blobs_failed: 0, upload_attempts: 3)
      expect(stat.outcome_counts).to eq('upload.error' => 2, 'upload.ok' => 1)
    end
  end

  describe 'blobs the pass abandoned' do
    it 'counts them against the pass rather than ignoring them' do
      stat = collect do |telemetry|
        telemetry.attempt(cid: 'bafy1', bytes: 10) { :uploaded }
        telemetry.skipped('bafy2')
        telemetry.skipped('bafy3')
      end

      expect(stat).to have_attributes(blobs_attempted: 3, blobs_succeeded: 1, blobs_failed: 2)
    end
  end

  describe 'download failures' do
    it 'labels the phase, and the blob still counts as not transferred' do
      stat = collect do |telemetry|
        telemetry.attempt(cid: 'bafy1', phase: :download) do
          raise GoatService::NetworkError.new('gone', http_status: 404, phase: :download)
        end
      rescue GoatService::NetworkError
        nil
      end

      expect(stat.outcome_counts).to eq('download.http_404' => 1)
      expect(stat).to have_attributes(blobs_attempted: 1, blobs_succeeded: 0, upload_attempts: 0)
    end
  end

  describe 'throughput' do
    it 'derives a per-upload rate from the measured bytes and time' do
      stat = collect do |telemetry|
        telemetry.attempt(cid: 'bafy1', bytes: 1_250_000) do
          sleep 0.05
          :uploaded
        end
      end

      expect(stat.upload_bps_p50).to be > 0
      expect(stat.upload_ms_p50).to be >= 50
      expect(stat.throughput_bps).to be > 0
    end
  end

  describe 'when the row cannot be written' do
    it 'logs and carries on rather than failing the migration' do
      allow(BlobTransferStat).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'no table')

      expect do
        collect { |telemetry| telemetry.attempt(cid: 'bafy1', bytes: 10) { :uploaded } }
      end.not_to raise_error
    end
  end
end
