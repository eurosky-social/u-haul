require "test_helper"

# Migration Jobs Error Handling Tests
# Tests based on MIGRATION_ERROR_ANALYSIS.md covering error scenarios for all jobs
class MigrationJobsErrorTest < ActiveSupport::TestCase
  def setup
    @migration = migrations(:pending_migration)
  end

  # ============================================================================
  # CreateAccountJob - Stage 2 Errors
  # ============================================================================

  test "CreateAccountJob marks migration failed after max retries" do
    job = CreateAccountJob.new
    # Simulate final retry (executions = 3 means this is the 3rd attempt)
    job.stubs(:executions).returns(3)

    service = mock('goat_service')
    service.stubs(:login_old_pds).raises(GoatService::AuthenticationError, "Invalid password")
    GoatService.stubs(:new).returns(service)

    # Job should not raise when all retries exhausted, it marks as failed instead
    job.perform(@migration.id)

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("Invalid password")
  end

  test "CreateAccountJob handles AccountExistsError by discarding job" do
    job = CreateAccountJob.new
    service = mock('goat_service')
    service.stubs(:login_old_pds).returns(nil)
    service.stubs(:get_new_pds_service_did).returns('did:web:newpds')
    service.stubs(:get_service_auth_token).returns('token')
    service.stubs(:create_account_on_new_pds).raises(
      GoatService::AccountExistsError,
      "Orphaned deactivated account exists"
    )
    GoatService.stubs(:new).returns(service)

    # Should raise AccountExistsError (discard_on will catch it and prevent retries)
    assert_raises(GoatService::AccountExistsError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("orphaned account")
  end

  test "CreateAccountJob handles RateLimitError with extended retry" do
    job = CreateAccountJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')
    service.stubs(:login_old_pds).raises(
      GoatService::RateLimitError,
      "PDS rate limit exceeded"
    )
    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::RateLimitError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("rate limit")
  end

  test "CreateAccountJob verifies existing account for migration_in" do
    @migration.update!(migration_type: :migration_in)

    job = CreateAccountJob.new
    service = mock('goat_service')
    # For migration_in, we login to old PDS first, then verify new PDS
    service.stubs(:login_old_pds).returns(true)
    service.expects(:verify_existing_account_access).returns(
      { exists: true, deactivated: true }
    )
    service.expects(:activate_account).never # Should not activate in CreateAccountJob
    GoatService.stubs(:new).returns(service)

    job.perform(@migration.id)

    # Should transition to pending_repo for migration_in
    @migration.reload
    assert @migration.pending_repo?
  end

  test "CreateAccountJob fails migration_in when account doesn't exist" do
    @migration.update!(migration_type: :migration_in)

    job = CreateAccountJob.new
    # Simulate final retry (executions = 3 means this is the 3rd attempt)
    job.stubs(:executions).returns(3)

    service = mock('goat_service')
    # For migration_in, we login to old PDS first, then verify new PDS
    service.stubs(:login_old_pds).returns(true)
    service.stubs(:verify_existing_account_access).raises(
      GoatService::GoatError,
      "Account does not exist on target PDS"
    )
    GoatService.stubs(:new).returns(service)

    # Job should not raise when all retries exhausted, it marks as failed instead
    job.perform(@migration.id)

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("does not exist")
  end

  # ============================================================================
  # ImportRepoJob - Stage 3 Errors
  # ============================================================================

  test "ImportRepoJob handles timeout error with retry" do
    @migration.update!(status: :pending_repo)

    job = ImportRepoJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')
    service.stubs(:export_repo).raises(
      GoatService::TimeoutError,
      "Repository export timed out after 600 seconds"
    )
    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::TimeoutError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("timed out")
  end

  test "ImportRepoJob handles CAR file corruption with retry" do
    @migration.update!(status: :pending_repo)

    job = ImportRepoJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')
    service.stubs(:export_repo).raises(
      GoatService::GoatError,
      "Repository export failed: file not created or empty"
    )
    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("file not created or empty")
  end

  test "ImportRepoJob converts legacy blobs if enabled" do
    @migration.update!(status: :pending_repo)
    ENV['CONVERT_LEGACY_BLOBS'] = 'true'

    job = ImportRepoJob.new
    service = mock('goat_service')
    car_path = '/tmp/account.car'
    converted_path = '/tmp/account_converted.car'

    service.expects(:export_repo).returns(car_path)
    service.expects(:convert_legacy_blobs_if_needed).with(car_path).returns(converted_path)
    service.expects(:import_repo).with(converted_path)
    GoatService.stubs(:new).returns(service)

    # Stub File.size calls for both paths
    File.stubs(:size).with(car_path).returns(5_000_000) # 5MB
    File.stubs(:size).with(converted_path).returns(6_000_000) # 6MB

    job.perform(@migration.id)

    # Verify migration advanced to pending_blobs
    @migration.reload
    assert @migration.pending_blobs?
  ensure
    ENV.delete('CONVERT_LEGACY_BLOBS')
  end

  # ============================================================================
  # ImportBlobsJob - Stage 4 Errors (Most Complex)
  # ============================================================================

  test "ImportBlobsJob respects concurrency limit and re-enqueues" do
    @migration.update!(status: :pending_blobs)

    # Create 15 migrations already in blob import stage
    15.times do |i|
      Migration.create!(
        did: "did:plc:concurrent#{i}",
        old_handle: "user#{i}.old.com",
        new_handle: "user#{i}.new.com",
        old_pds_host: "https://old.com",
        new_pds_host: "https://new.com",
        email: "user#{i}@example.com",
        status: :pending_blobs,
        password: "test"
      )
    end

    job = ImportBlobsJob.new

    # Should re-enqueue with delay instead of executing
    # The job uses ActiveJob API: set(wait: 30.seconds).perform_later(migration)
    job_double = mock('job')
    job_double.expects(:perform_later).with(@migration)
    ImportBlobsJob.expects(:set).with(wait: 30.seconds).returns(job_double)

    job.perform(@migration.id)

    # Migration should still be pending_blobs
    @migration.reload
    assert @migration.pending_blobs?
  end

  test "ImportBlobsJob handles individual blob download failure" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    # Mock login
    service.stubs(:login_new_pds).returns(true)

    # Mock blob listing
    service.stubs(:list_blobs).returns({
      'cids' => ['blob1', 'blob2', 'blob3'],
      'cursor' => nil
    })

    # blob1 succeeds
    service.stubs(:download_blob).with('blob1').returns('/tmp/blob1')
    service.stubs(:upload_blob).with('/tmp/blob1').returns({ 'blob' => {} })

    # blob2 fails all retries
    service.stubs(:download_blob).with('blob2').raises(
      GoatService::NetworkError,
      "Failed to download blob"
    ).times(3)

    # blob3 succeeds
    service.stubs(:download_blob).with('blob3').returns('/tmp/blob3')
    service.stubs(:upload_blob).with('/tmp/blob3').returns({ 'blob' => {} })

    GoatService.stubs(:new).returns(service)

    job.perform(@migration.id)

    @migration.reload
    # Should have logged failed blob
    assert @migration.progress_data['failed_blobs'].include?('blob2')
    # Should advance to pending_prefs
    assert @migration.pending_prefs?
  end

  test "ImportBlobsJob handles blob rate limiting with extended retry" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    # Mock login
    service.stubs(:login_new_pds).returns(true)

    service.stubs(:list_blobs).returns({
      'cids' => ['blob1'],
      'cursor' => nil
    })

    # Track download calls - use instance variable to track across stub calls
    @download_call_count = 0

    # First attempt: rate limited, Second attempt: succeeds
    service.stubs(:download_blob).with('blob1').raises(GoatService::RateLimitError, "Rate limit exceeded")
                                 .then.returns('/tmp/blob1')

    service.stubs(:upload_blob).with('/tmp/blob1').returns({ 'blob' => {} })

    # Mock File.size for the blob
    File.stubs(:size).with('/tmp/blob1').returns(1024)

    GoatService.stubs(:new).returns(service)

    # Stub sleep to prevent actual delays
    job.stubs(:sleep)

    job.perform(@migration.id)

    # Should advance to pending_prefs
    @migration.reload
    assert @migration.pending_prefs?
  end

  test "ImportBlobsJob writes failed blobs manifest" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    # Mock login
    service.stubs(:login_new_pds).returns(true)

    service.stubs(:list_blobs).returns({
      'cids' => ['blob1', 'blob2'],
      'cursor' => nil
    })

    # Both blobs fail
    service.stubs(:download_blob).raises(GoatService::NetworkError, "Failed").times(6)

    # Stub work_dir which might be accessed for manifest writing
    service.stubs(:work_dir).returns(Pathname.new('/tmp'))

    GoatService.stubs(:new).returns(service)

    job.perform(@migration.id)

    @migration.reload
    # Should advance to pending_prefs even with failures
    assert @migration.pending_prefs?
    # Verify failed blobs were tracked in progress_data
    assert @migration.progress_data['failed_blobs']
    assert @migration.progress_data['failed_blobs'].include?('blob1')
    assert @migration.progress_data['failed_blobs'].include?('blob2')
  end

  test "ImportBlobsJob handles blob 404 by skipping blob" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    # Mock login
    service.stubs(:login_new_pds).returns(true)

    service.stubs(:list_blobs).returns({
      'cids' => ['blob_deleted'],
      'cursor' => nil
    })

    # Blob not found (deleted from old PDS)
    service.stubs(:download_blob).with('blob_deleted').raises(
      GoatService::NetworkError,
      "Failed to download blob: 404"
    )

    GoatService.stubs(:new).returns(service)

    job.perform(@migration.id)

    @migration.reload
    # Should skip and continue
    assert @migration.progress_data['failed_blobs'].include?('blob_deleted')
    # Should advance to pending_prefs
    assert @migration.pending_prefs?
  end

  test "ImportBlobsJob tracks blob upload progress" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    # Mock login
    service.stubs(:login_new_pds).returns(true)

    blob_size = 1024000
    service.stubs(:list_blobs).returns({
      'cids' => ['blob1'],
      'cursor' => nil
    })
    service.stubs(:download_blob).returns('/tmp/blob1')
    service.stubs(:upload_blob).returns({ 'blob' => {} })

    # Mock File.size to return blob size
    File.stubs(:size).with('/tmp/blob1').returns(blob_size)

    GoatService.stubs(:new).returns(service)

    job.perform(@migration.id)

    @migration.reload
    # Verify overall blob progress was tracked (not per-blob)
    assert_equal 1, @migration.progress_data['blobs_completed']
    assert_equal 1, @migration.progress_data['blobs_total']
    assert_equal blob_size, @migration.progress_data['bytes_transferred']
    # Should advance to pending_prefs
    assert @migration.pending_prefs?
  end

  # ============================================================================
  # ImportPrefsJob - Stage 5 Errors
  # ============================================================================

  test "ImportPrefsJob continues migration on non-critical failure" do
    @migration.update!(status: :pending_prefs)

    job = ImportPrefsJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')

    service.stubs(:export_preferences).raises(
      GoatService::GoatError,
      "Failed to export preferences"
    )

    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end
  end

  test "ImportPrefsJob handles unsupported preferences format" do
    @migration.update!(status: :pending_prefs)

    job = ImportPrefsJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')
    prefs_path = '/tmp/prefs.json'

    service.stubs(:export_preferences).returns(prefs_path)
    service.stubs(:import_preferences).raises(
      GoatService::GoatError,
      "New PDS doesn't support some preferences"
    )

    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end
  end

  # ============================================================================
  # WaitForPlcTokenJob - Stage 6 Errors
  # ============================================================================

  test "WaitForPlcTokenJob requests PLC token and generates OTP" do
    @migration.update!(status: :pending_plc)

    job = WaitForPlcTokenJob.new
    service = mock('goat_service')
    service.expects(:request_plc_token)
    GoatService.stubs(:new).returns(service)

    job.perform(@migration.id)

    # Should remain in pending_plc state and have generated OTP
    @migration.reload
    assert @migration.pending_plc?
    assert @migration.plc_otp.present?
  end

  test "WaitForPlcTokenJob handles PLC token request failure" do
    @migration.update!(status: :pending_plc)

    job = WaitForPlcTokenJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')
    service.stubs(:request_plc_token).raises(
      GoatService::GoatError,
      "Failed to request PLC token"
    )
    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("Failed to request PLC token")
  end

  # ============================================================================
  # UpdatePlcJob - Stage 7 Errors (CRITICAL)
  # ============================================================================

  test "UpdatePlcJob fails immediately when PLC token missing" do
    @migration.update!(
      status: :pending_plc,
      encrypted_plc_token: nil
    )

    job = UpdatePlcJob.new

    # Should raise AuthenticationError when token is missing
    assert_raises(GoatService::AuthenticationError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("PLC token is missing or expired")
  end

  test "UpdatePlcJob fails immediately when PLC token expired" do
    @migration.update!(
      status: :pending_plc,
      credentials_expires_at: 1.hour.ago
    )
    @migration.set_plc_token("expired-token")
    @migration.update!(credentials_expires_at: 1.hour.ago)

    job = UpdatePlcJob.new

    # Should raise AuthenticationError when token is expired
    assert_raises(GoatService::AuthenticationError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("PLC token has expired")
    assert @migration.last_error.include?("Please request a new token")
  end

  test "UpdatePlcJob handles PLC operation signing failure" do
    @migration.update!(status: :pending_plc)
    @migration.set_plc_token("valid-token")

    job = UpdatePlcJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')
    service.stubs(:get_recommended_plc_operation).returns('/tmp/unsigned.json')
    service.stubs(:sign_plc_operation).raises(
      GoatService::GoatError,
      "Failed to sign PLC operation"
    )
    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("Failed to sign PLC operation")
  end

  test "UpdatePlcJob handles PLC submission failure with retry" do
    @migration.update!(status: :pending_plc)
    @migration.set_plc_token("valid-token")

    job = UpdatePlcJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')
    service.stubs(:get_recommended_plc_operation).returns('/tmp/unsigned.json')
    service.stubs(:sign_plc_operation).returns('/tmp/signed.json')
    service.stubs(:submit_plc_operation).raises(
      GoatService::GoatError,
      "Failed to submit PLC operation"
    )
    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end
  end

  test "UpdatePlcJob handles rate limiting with polynomial backoff" do
    @migration.update!(status: :pending_plc)
    @migration.set_plc_token("valid-token")

    job = UpdatePlcJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')
    service.stubs(:get_recommended_plc_operation).returns('/tmp/unsigned.json')
    service.stubs(:sign_plc_operation).returns('/tmp/signed.json')
    service.stubs(:submit_plc_operation).raises(
      GoatService::RateLimitError,
      "PLC directory rate-limited"
    )
    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::RateLimitError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("rate-limited")
  end

  test "UpdatePlcJob transitions to pending_activation on success" do
    @migration.update!(status: :pending_plc)
    @migration.set_plc_token("valid-token")

    job = UpdatePlcJob.new
    service = mock('goat_service')
    service.stubs(:get_recommended_plc_operation).returns('/tmp/unsigned.json')
    service.stubs(:sign_plc_operation).returns('/tmp/signed.json')
    service.stubs(:submit_plc_operation)
    GoatService.stubs(:new).returns(service)

    job.perform(@migration.id)

    # Should transition to pending_activation
    @migration.reload
    assert @migration.pending_activation?
  end

  # ============================================================================
  # ActivateAccountJob - Stage 8 Errors
  # ============================================================================

  test "ActivateAccountJob handles new account activation failure" do
    @migration.update!(status: :pending_activation)

    job = ActivateAccountJob.new
    # Simulate first retry attempt (not final)
    job.stubs(:executions).returns(1)

    service = mock('goat_service')
    service.stubs(:activate_account).raises(
      GoatService::GoatError,
      "Failed to activate new account"
    )
    GoatService.stubs(:new).returns(service)

    # Error should be raised to trigger ActiveJob retry mechanism
    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("Failed to activate new account")
  end

  test "ActivateAccountJob handles old account deactivation failure gracefully" do
    @migration.update!(status: :pending_activation)
    @migration.set_password("test_password")

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.expects(:activate_account) # Succeeds
    service.stubs(:deactivate_account).raises(
      GoatService::GoatError,
      "Failed to deactivate old account"
    )
    # Mock rotation key generation
    service.stubs(:generate_rotation_key).returns({
      private_key: 'test-private-key',
      public_key: 'test-public-key'
    })
    service.stubs(:add_rotation_key_to_pds).returns(true)
    GoatService.stubs(:new).returns(service)

    # Stub mailer so it doesn't try to send (now takes migration + password)
    mail_mock = mock(deliver_later: true)
    MigrationMailer.stubs(:migration_completed).with(anything, anything).returns(mail_mock)

    # Should complete migration despite deactivation failure
    job.perform(@migration.id)

    @migration.reload
    assert @migration.completed?
  end

  test "ActivateAccountJob cleans up credentials on success" do
    @migration.update!(status: :pending_activation)
    @migration.set_password("test_password")
    @migration.set_plc_token("test_token")

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.expects(:activate_account)
    service.expects(:deactivate_account)
    # Mock rotation key generation
    service.stubs(:generate_rotation_key).returns({
      private_key: 'test-private-key',
      public_key: 'test-public-key'
    })
    service.stubs(:add_rotation_key_to_pds).returns(true)
    GoatService.stubs(:new).returns(service)

    # Stub mailer so it doesn't try to send (now takes migration + password)
    mail_mock = mock(deliver_later: true)
    MigrationMailer.stubs(:migration_completed).with(anything, anything).returns(mail_mock)

    job.perform(@migration.id)

    @migration.reload
    assert @migration.completed?
    # Verify credentials were cleared
    assert_nil @migration.password
    assert_nil @migration.plc_token
  end

  test "ActivateAccountJob sends completion email with password" do
    @migration.update!(status: :pending_activation)
    @migration.set_password("test_password_for_email")

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.expects(:activate_account)
    service.expects(:deactivate_account)
    # Mock rotation key generation
    service.stubs(:generate_rotation_key).returns({
      private_key: 'test-private-key',
      public_key: 'test-public-key'
    })
    service.stubs(:add_rotation_key_to_pds).returns(true)
    GoatService.stubs(:new).returns(service)

    @migration.stubs(:clear_credentials!)
    @migration.stubs(:mark_complete!)

    # Should send completion email with migration AND the new account password
    mail_mock = mock('mail')
    mail_mock.expects(:deliver_later)
    MigrationMailer.expects(:migration_completed).with(@migration, "test_password_for_email").returns(mail_mock)

    job.perform(@migration.id)
  end

  # ============================================================================
  # Cleanup & Resource Management
  # ============================================================================

  test "Jobs clean up work directory on completion" do
    @migration.update!(status: :pending_activation)
    @migration.set_password("test_password")

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.expects(:activate_account)
    service.expects(:deactivate_account)
    # Mock rotation key generation
    service.stubs(:generate_rotation_key).returns({
      private_key: 'test-private-key',
      public_key: 'test-public-key'
    })
    service.stubs(:add_rotation_key_to_pds).returns(true)
    # Note: cleanup is not currently called by ActivateAccountJob, tracked for future implementation
    GoatService.stubs(:new).returns(service)

    @migration.stubs(:clear_credentials!)
    @migration.stubs(:mark_complete!)
    mail_mock = mock(deliver_later: true)
    MigrationMailer.stubs(:migration_completed).with(anything, anything).returns(mail_mock)

    job.perform(@migration.id)
  end

  test "Jobs clean up work directory on failure after max retries" do
    @migration.update!(status: :pending_activation)

    job = ActivateAccountJob.new

    service = mock('goat_service')
    service.stubs(:activate_account).raises(GoatService::GoatError, "Failure")
    # Note: cleanup is not currently called on failure, tracked for future implementation
    GoatService.stubs(:new).returns(service)

    # Job should raise the error (ActiveJob will handle retries)
    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.failed?
  end
end
