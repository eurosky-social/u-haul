# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StuckMigrationSweeperJob, type: :job do
  def build_migration(attrs = {})
    Migration.create!({
      email: "test@example.com",
      did: "did:plc:test#{SecureRandom.hex(6)}",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: :pending_account
    }.merge(attrs))
  end

  before do
    # No jobs anywhere in Sidekiq
    allow(Sidekiq::Queue).to receive(:all).and_return([])
    allow(Sidekiq::ScheduledSet).to receive(:new).and_return([])
    allow(Sidekiq::RetrySet).to receive(:new).and_return([])
    allow(Sidekiq::WorkSet).to receive(:new).and_return([])
  end

  it 'never starts a migration whose email is not verified yet' do
    migration = build_migration
    migration.update_columns(updated_at: 30.minutes.ago)

    expect(CreateAccountJob).not_to receive(:perform_later)
    described_class.perform_now

    expect(migration.reload.status).to eq('pending_account')
  end

  it 're-enqueues a verified migration that is idle without a job' do
    migration = build_migration(email_verified_at: 1.hour.ago)
    migration.update_columns(updated_at: 30.minutes.ago)

    expect(CreateAccountJob).to receive(:perform_later).with(migration.id)
    described_class.perform_now
  end

  it 'leaves a recently updated migration alone' do
    build_migration(email_verified_at: 1.hour.ago)

    expect(CreateAccountJob).not_to receive(:perform_later)
    described_class.perform_now
  end
end
