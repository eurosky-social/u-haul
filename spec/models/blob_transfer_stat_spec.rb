# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BlobTransferStat do
  let(:migration) { create_test_migration(status: :pending_blobs) }

  def stat(attributes = {})
    described_class.create!({
      migration: migration,
      job_name: 'ImportBlobsJob',
      pass: 'parallel',
      # The telemetry always records the target; rows without one are not a
      # shape production produces.
      target_host: migration.new_pds_host,
      started_at: Time.current,
      blobs_attempted: 100,
      blobs_succeeded: 90,
      blobs_failed: 10,
      upload_attempts: 130,
      outcome_counts: { 'upload.ok' => 90, 'upload.http_500' => 40 }
    }.merge(attributes))
  end

  describe '#success_rate' do
    it 'is the share of blobs the pass moved' do
      expect(stat.success_rate).to eq(0.9)
    end

    it 'is nil for a pass with nothing to do, so it cannot flatter an average' do
      expect(stat(blobs_attempted: 0, blobs_succeeded: 0, blobs_failed: 0).success_rate).to be_nil
    end
  end

  describe '#attempts_per_blob' do
    it 'exposes retry pressure' do
      expect(stat.attempts_per_blob).to eq(1.3)
    end
  end

  describe '#failure_profile' do
    it 'drops the successes and orders the rest by weight' do
      row = stat(outcome_counts: { 'upload.ok' => 90, 'upload.timeout' => 5, 'upload.http_500' => 40 })

      expect(row.failure_profile.keys).to eq(%w[upload.http_500 upload.timeout])
    end
  end

  describe '.summary' do
    it 'groups passes by the PDS version they ran against' do
      stat(target_pds_version: '0.5.10', blobs_attempted: 100, blobs_succeeded: 80,
           upload_bps_p50: 1_250_000, outcome_counts: { 'upload.ok' => 80, 'upload.http_500' => 20 })
      stat(target_pds_version: '0.5.10', blobs_attempted: 100, blobs_succeeded: 90,
           upload_bps_p50: 1_250_000, outcome_counts: { 'upload.ok' => 90, 'upload.timeout' => 10 })
      stat(target_pds_version: '0.5.29', blobs_attempted: 50, blobs_succeeded: 50,
           upload_bps_p50: 12_000_000, outcome_counts: { 'upload.ok' => 50 })

      summary = described_class.summary(since: 1.day.ago)
      old_version = summary.find { |entry| entry[:target_pds_version] == '0.5.10' }
      new_version = summary.find { |entry| entry[:target_pds_version] == '0.5.29' }

      expect(old_version[:target_host]).to eq(migration.new_pds_host)

      expect(old_version).to include(passes: 2, blobs_attempted: 200, blobs_succeeded: 170,
                                     blobs_failed: 30, success_rate: 0.85)
      expect(old_version[:outcomes]).to eq('upload.ok' => 170, 'upload.http_500' => 20, 'upload.timeout' => 10)
      expect(new_version).to include(passes: 1, success_rate: 1.0, upload_bps_p50: 12_000_000)
    end

    # Migrations run in both directions, so two different targets can report the
    # same version string - and one of them is not even a version: bsky.social's
    # /xrpc/_health answers with a git SHA. Keyed on the version alone these
    # collapsed into one row that belonged to neither host.
    it 'does not merge two targets that report the same version' do
      stat(target_host: 'https://eurosky.social', target_pds_version: '0.5.10',
           blobs_attempted: 100, blobs_succeeded: 50, blobs_failed: 50)
      stat(target_host: 'https://bsky.social', target_pds_version: '0.5.10',
           blobs_attempted: 100, blobs_succeeded: 100, blobs_failed: 0)

      summary = described_class.summary(since: 1.day.ago)
      eurosky = summary.find { |entry| entry[:target_host] == 'https://eurosky.social' }
      bsky    = summary.find { |entry| entry[:target_host] == 'https://bsky.social' }

      expect(summary.length).to eq(2)
      expect(eurosky[:success_rate]).to eq(0.5)
      expect(bsky[:success_rate]).to eq(1.0)
    end

    it 'keeps a git SHA apart from a semver on a different host' do
      sha = '88465e2115f5b1f0c5c230d9e96cf0a4311e1980'
      stat(target_host: 'https://bsky.social', target_pds_version: sha)
      stat(target_host: 'https://eurosky.social', target_pds_version: '0.5.10')

      versions = described_class.summary(since: 1.day.ago).map { |e| e[:target_pds_version] }
      expect(versions).to contain_exactly(sha, '0.5.10')
    end

    it 'labels rows with no version rather than dropping them' do
      stat(target_pds_version: nil)

      expect(described_class.summary(since: 1.day.ago).first[:target_pds_version]).to eq('unknown')
    end

    it 'ignores passes outside the window' do
      stat(target_pds_version: '0.5.10').update!(created_at: 30.days.ago)

      expect(described_class.summary(since: 7.days.ago)).to be_empty
    end
  end

  describe 'outliving the migration it came from' do
    # CleanupOldMigrationsJob destroys migrations after 2-7 days. If the stats
    # went with them, no before/after comparison could span a PDS upgrade.
    it 'survives the migration being destroyed' do
      row = stat
      migration.destroy!

      expect(row.reload.migration_id).to be_nil
      expect(row.blobs_attempted).to eq(100)
    end
  end
end
