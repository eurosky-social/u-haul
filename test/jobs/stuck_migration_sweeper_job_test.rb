require "test_helper"

class StuckMigrationSweeperJobTest < ActiveSupport::TestCase
  def setup
    @valid_attributes = {
      did: "did:plc:sweeper123",
      old_handle: "user.oldpds.com",
      new_handle: "user.newpds.com",
      old_pds_host: "https://oldpds.com",
      new_pds_host: "https://newpds.com",
      email: "sweeper@example.com",
      migration_type: "migration_out",
      password: "test"
    }
  end

  test "re-enqueues job for migration stuck at pending_blobs" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_blobs
    ))
    # Simulate being stuck for longer than the threshold
    migration.update_columns(updated_at: 15.minutes.ago)

    # Mock Sidekiq queues as empty (no active jobs)
    stub_empty_sidekiq_queues

    assert_enqueued_with(job: ImportBlobsJob, args: [migration.id]) do
      StuckMigrationSweeperJob.perform_now
    end
  end

  test "re-enqueues job for migration stuck at pending_repo" do
    migration = Migration.create!(@valid_attributes.merge(
      did: "did:plc:sweeperrepo",
      status: :pending_repo
    ))
    migration.update_columns(updated_at: 15.minutes.ago)

    stub_empty_sidekiq_queues

    assert_enqueued_with(job: ImportRepoJob, args: [migration.id]) do
      StuckMigrationSweeperJob.perform_now
    end
  end

  test "re-enqueues job for migration stuck at pending_account" do
    migration = Migration.create!(@valid_attributes.merge(
      did: "did:plc:sweeperacct",
      status: :pending_account
    ))
    migration.update_columns(updated_at: 15.minutes.ago)

    stub_empty_sidekiq_queues

    assert_enqueued_with(job: CreateAccountJob, args: [migration.id]) do
      StuckMigrationSweeperJob.perform_now
    end
  end

  test "does not re-enqueue if migration was recently updated" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_blobs
    ))
    # Updated just now — not stuck yet
    migration.update_columns(updated_at: 2.minutes.ago)

    stub_empty_sidekiq_queues

    assert_no_enqueued_jobs(only: ImportBlobsJob) do
      StuckMigrationSweeperJob.perform_now
    end
  end

  test "does not re-enqueue if Sidekiq already has job for migration" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_blobs
    ))
    migration.update_columns(updated_at: 15.minutes.ago)

    # Simulate Sidekiq having an active job for this migration
    stub_sidekiq_queues_with_migration_id(migration.id)

    assert_no_enqueued_jobs(only: ImportBlobsJob) do
      StuckMigrationSweeperJob.perform_now
    end
  end

  # Regression: a long-running blob transfer (hours) only appears in the busy
  # WorkSet, not in Queue/Scheduled/Retry. Before the WorkSet check, the
  # sweeper treated it as orphaned and re-enqueued a DUPLICATE every cycle,
  # piling up concurrent jobs that overwhelmed the destination PDS.
  test "does not re-enqueue if migration has a currently-running job (WorkSet)" do
    migration = Migration.create!(@valid_attributes.merge(
      did: "did:plc:sweeperrunning",
      status: :pending_blobs
    ))
    # Idle by updated_at (large transfer bumps it infrequently), yet the job
    # is actively executing on a worker.
    migration.update_columns(updated_at: 30.minutes.ago)

    stub_sidekiq_workset_with_migration_id(migration.id)

    assert_no_enqueued_jobs(only: ImportBlobsJob) do
      StuckMigrationSweeperJob.perform_now
    end
  end

  test "skips migrations at pending_plc (waiting for user action)" do
    migration = Migration.create!(@valid_attributes.merge(
      did: "did:plc:sweeperplc",
      status: :pending_plc
    ))
    migration.update_columns(updated_at: 1.hour.ago)

    stub_empty_sidekiq_queues

    assert_no_enqueued_jobs(only: WaitForPlcTokenJob) do
      StuckMigrationSweeperJob.perform_now
    end
  end

  test "skips completed and failed migrations" do
    # Move all fixture migrations to completed to isolate this test
    Migration.update_all(status: :completed)

    m1 = Migration.create!(@valid_attributes.merge(
      did: "did:plc:sweeperdone",
      status: :completed
    ))
    m1.update_columns(updated_at: 1.hour.ago)

    m2 = Migration.create!(@valid_attributes.merge(
      did: "did:plc:sweeperfail",
      status: :failed
    ))
    m2.update_columns(updated_at: 1.hour.ago)

    stub_empty_sidekiq_queues

    # Clear mailer jobs triggered by after_create_commit
    queue_adapter.enqueued_jobs.clear

    StuckMigrationSweeperJob.perform_now

    enqueued_classes = queue_adapter.enqueued_jobs.map { |j| j[:job] }
    migration_jobs = [CreateAccountJob, ImportRepoJob, ImportBlobsJob,
                      UploadRepoJob, UploadBlobsJob, ImportPrefsJob,
                      WaitForPlcTokenJob, ActivateAccountJob]
    assert_empty enqueued_classes & migration_jobs, "No migration jobs should be enqueued for completed/failed migrations"
  end

  test "re-enqueues UploadBlobsJob when backup bundle was used" do
    migration = Migration.create!(@valid_attributes.merge(
      did: "did:plc:sweeperbackup",
      status: :pending_blobs,
      create_backup_bundle: true,
      downloaded_data_path: "/tmp/eurosky/test_data"
    ))
    migration.update_columns(updated_at: 15.minutes.ago)

    stub_empty_sidekiq_queues

    assert_enqueued_with(job: UploadBlobsJob, args: [migration.id]) do
      StuckMigrationSweeperJob.perform_now
    end
  end

  test "handles multiple stuck migrations in one sweep" do
    m1 = Migration.create!(@valid_attributes.merge(
      did: "did:plc:sweepermulti1",
      status: :pending_blobs
    ))
    m2 = Migration.create!(@valid_attributes.merge(
      did: "did:plc:sweepermulti2",
      status: :pending_repo
    ))
    m1.update_columns(updated_at: 15.minutes.ago)
    m2.update_columns(updated_at: 15.minutes.ago)

    stub_empty_sidekiq_queues

    StuckMigrationSweeperJob.perform_now

    enqueued_classes = enqueued_jobs.map { |j| j[:job] }
    assert_includes enqueued_classes, ImportBlobsJob
    assert_includes enqueued_classes, ImportRepoJob
  end

  private

  def stub_empty_sidekiq_queues
    empty_queue = []
    empty_queue.stubs(:each).returns([].each)

    Sidekiq::Queue.stubs(:all).returns([])
    Sidekiq::ScheduledSet.stubs(:new).returns(empty_queue)
    Sidekiq::RetrySet.stubs(:new).returns(empty_queue)
    Sidekiq::WorkSet.stubs(:new).returns(empty_queue)
  end

  def stub_sidekiq_queues_with_migration_id(migration_id)
    # Create a fake Sidekiq job entry with ActiveJob argument format
    fake_job = stub(args: [{ 'arguments' => [migration_id] }])

    queue = stub
    queue.stubs(:each).yields(fake_job)

    queue_wrapper = stub
    queue_wrapper.stubs(:each).yields(queue)

    Sidekiq::Queue.stubs(:all).returns([queue])
    Sidekiq::ScheduledSet.stubs(:new).returns([])
    Sidekiq::RetrySet.stubs(:new).returns([])
    Sidekiq::WorkSet.stubs(:new).returns([])
  end

  # Simulate a job currently EXECUTING on a busy worker for the given migration.
  # WorkSet#each yields (process_id, thread_id, work), where work responds to
  # #payload with the raw Sidekiq job hash (args = ActiveJob wrapper).
  def stub_sidekiq_workset_with_migration_id(migration_id)
    work = stub(payload: { 'args' => [{ 'arguments' => [migration_id] }] })

    workset = stub
    workset.stubs(:each).yields('process-id', 'thread-id', work)

    Sidekiq::Queue.stubs(:all).returns([])
    Sidekiq::ScheduledSet.stubs(:new).returns([])
    Sidekiq::RetrySet.stubs(:new).returns([])
    Sidekiq::WorkSet.stubs(:new).returns(workset)
  end
end
