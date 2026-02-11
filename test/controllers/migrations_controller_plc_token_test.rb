require "test_helper"

# MigrationsController PLC Token Tests
# Tests for PLC token expiration handling and resend functionality
class MigrationsControllerPlcTokenTest < ActionDispatch::IntegrationTest
  def setup
    @pending_plc_migration = migrations(:pending_migration)
    @pending_plc_migration.update!(
      status: :pending_plc,
      old_pds_host: 'https://oldpds.example.com',
      new_pds_host: 'https://newpds.example.com'
    )
    @pending_plc_migration.set_plc_token("valid-token")
  end

  # ============================================================================
  # request_new_plc_token Action Tests
  # ============================================================================

  test "request_new_plc_token successfully requests new token when migration is pending_plc" do
    service = mock('goat_service')
    service.expects(:request_plc_token).once
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/new PLC token has been requested/i, flash[:notice])
    assert_match(/#{@pending_plc_migration.old_pds_host}/, flash[:notice])

    @pending_plc_migration.reload
    assert @pending_plc_migration.progress_data['plc_token_requested_at'].present?
    assert @pending_plc_migration.progress_data['plc_token_resent']
  end

  test "request_new_plc_token resets failed migration with expired token to pending_plc" do
    @pending_plc_migration.update!(
      status: :failed,
      last_error: "PLC token has expired (expired at: #{1.hour.ago}). Please request a new token."
    )

    service = mock('goat_service')
    service.expects(:request_plc_token).once
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    @pending_plc_migration.reload
    assert @pending_plc_migration.pending_plc?
    assert_nil @pending_plc_migration.last_error
  end

  test "request_new_plc_token rejects request when migration not in correct status" do
    @pending_plc_migration.update!(status: :completed)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/cannot request.*at this stage/i, flash[:alert])
  end

  test "request_new_plc_token allows request when migration failed with PLC token error" do
    @pending_plc_migration.update!(
      status: :failed,
      last_error: "PLC token has expired. Please request a new token."
    )

    service = mock('goat_service')
    service.expects(:request_plc_token).once
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/new PLC token has been requested/i, flash[:notice])
  end

  test "request_new_plc_token rejects request when migration failed without PLC token error" do
    @pending_plc_migration.update!(
      status: :failed,
      last_error: "Network error during blob transfer"
    )

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/cannot request.*at this stage/i, flash[:alert])
  end

  test "request_new_plc_token handles GoatService error gracefully" do
    service = mock('goat_service')
    service.stubs(:request_plc_token).raises(GoatService::NetworkError, "Network timeout")
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/failed to request.*new PLC token/i, flash[:alert])
  end

  # ============================================================================
  # Integration with submit_plc_token Action
  # ============================================================================

  test "submit_plc_token triggers UpdatePlcJob with new token after resend" do
    # Simulate token resend
    @pending_plc_migration.progress_data['plc_token_resent'] = true
    @pending_plc_migration.save!

    assert_enqueued_with(job: UpdatePlcJob, args: [@pending_plc_migration.id]) do
      post submit_plc_token_by_token_path(@pending_plc_migration.token),
           params: { plc_token: "new-fresh-token" }
    end

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/PLC token submitted/i, flash[:notice])

    @pending_plc_migration.reload
    assert_equal "new-fresh-token", @pending_plc_migration.plc_token
  end
end
