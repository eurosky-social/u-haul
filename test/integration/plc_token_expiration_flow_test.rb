require "test_helper"

# PLC Token Expiration Flow Integration Test
# Tests the complete flow from token expiration to successful resend and recovery
class PlcTokenExpirationFlowTest < ActionDispatch::IntegrationTest
  def setup
    @migration = migrations(:pending_migration)
    @migration.update!(
      status: :pending_plc,
      old_pds_host: 'https://oldpds.example.com',
      new_pds_host: 'https://newpds.example.com',
      email: 'test@example.com',
      did: 'did:plc:test123abc'
    )
  end

  # ============================================================================
  # Complete Flow: Token Expiration -> Request New -> Submit New -> Success
  # ============================================================================

  test "complete flow: user submits expired token, requests new one, and completes migration" do
    # Step 1: User has an expired token
    @migration.set_plc_token("expired-token")
    @migration.update!(credentials_expires_at: 1.hour.ago)

    # Step 2: User tries to submit the expired token via UpdatePlcJob
    job = UpdatePlcJob.new
    assert_raises(GoatService::AuthenticationError) do
      job.perform(@migration.id)
    end

    # Step 3: Migration is marked as failed with expiration error
    @migration.reload
    assert @migration.failed?
    assert_match(/PLC token has expired/i, @migration.last_error)
    assert_match(/request a new token/i, @migration.last_error)

    # Step 4: User views status page and sees error context
    get migration_by_token_path(@migration.token)
    assert_response :success
    assert_select 'div.error-details-section' do
      assert_select 'h3', text: /PLC Token Expired/i
    end

    # Step 5: Error helper identifies the error type correctly
    error_context = MigrationErrorHelper.explain_error(@migration)
    assert_equal :plc_token_expired, MigrationErrorHelper.detect_error_type(@migration.last_error)
    assert error_context[:show_request_new_plc_token]

    # Step 6: User clicks "Request New PLC Token" button
    service = mock('goat_service')
    service.expects(:request_plc_token).once
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@migration.token)
    assert_redirected_to migration_by_token_path(@migration.token)
    follow_redirect!
    assert_match(/new PLC token has been requested/i, flash[:notice])

    # Step 7: Migration is reset to pending_plc status
    @migration.reload
    assert @migration.pending_plc?
    assert_nil @migration.last_error
    assert @migration.progress_data['plc_token_resent']

    # Step 8: User receives fresh token via email and submits it
    new_token = "fresh-plc-token-12345"

    # Step 9: User submits the new token
    assert_enqueued_with(job: UpdatePlcJob, args: [@migration.id]) do
      post submit_plc_token_by_token_path(@migration.token),
           params: { plc_token: new_token }
    end

    assert_redirected_to migration_by_token_path(@migration.token)
    assert_match(/PLC token submitted/i, flash[:notice])

    # Step 10: Verify new token is stored and not expired
    @migration.reload
    assert_equal new_token, @migration.plc_token
    assert_not @migration.credentials_expired?
    assert @migration.credentials_expires_at > Time.current

    # Step 11: UpdatePlcJob should now succeed with fresh token
    job = UpdatePlcJob.new
    service = mock('goat_service')
    service.stubs(:get_recommended_plc_operation).returns('/tmp/unsigned.json')
    service.stubs(:sign_plc_operation).returns('/tmp/signed.json')
    service.stubs(:submit_plc_operation)
    GoatService.stubs(:new).returns(service)

    job.perform(@migration.id)

    # Step 12: Migration advances to pending_activation
    @migration.reload
    assert @migration.pending_activation?
    assert_nil @migration.last_error
  end

  # ============================================================================
  # Error Cases
  # ============================================================================

  test "request new token fails when migration not in correct status" do
    @migration.update!(status: :completed)

    post request_new_plc_token_by_token_path(@migration.token)

    assert_redirected_to migration_by_token_path(@migration.token)
    assert_match(/cannot request/i, flash[:alert])

    @migration.reload
    assert @migration.completed?
    assert_not @migration.progress_data&.dig('plc_token_resent')
  end

  test "request new token allowed only for PLC-related failures" do
    # Test with non-PLC error
    @migration.update!(
      status: :failed,
      last_error: "Network timeout during blob transfer"
    )

    post request_new_plc_token_by_token_path(@migration.token)
    assert_match(/cannot request/i, flash[:alert])

    # Test with PLC token error
    @migration.update!(
      last_error: "PLC token has expired. Please request a new token."
    )

    service = mock('goat_service')
    service.expects(:request_plc_token).once
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@migration.token)
    assert_match(/new PLC token has been requested/i, flash[:notice])
  end

  test "UpdatePlcJob distinguishes missing token from expired token" do
    # Test with missing token
    @migration.update!(encrypted_plc_token: nil)
    job = UpdatePlcJob.new

    assert_raises(GoatService::AuthenticationError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert_match(/PLC token is missing/i, @migration.last_error)
    assert_not_match(/expired/i, @migration.last_error)

    # Test with expired token
    @migration.set_plc_token("expired-token")
    @migration.update!(credentials_expires_at: 1.hour.ago)
    job = UpdatePlcJob.new

    assert_raises(GoatService::AuthenticationError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert_match(/PLC token has expired/i, @migration.last_error)
    assert_match(/request a new token/i, @migration.last_error)
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  test "multiple token resend requests update timestamp" do
    service = mock('goat_service')
    service.expects(:request_plc_token).twice
    GoatService.stubs(:new).returns(service)

    # First request
    post request_new_plc_token_by_token_path(@migration.token)
    @migration.reload
    first_timestamp = @migration.progress_data['plc_token_requested_at']
    assert_not_nil first_timestamp

    # Wait a moment to ensure timestamp changes
    sleep 0.01

    # Second request
    post request_new_plc_token_by_token_path(@migration.token)
    @migration.reload
    second_timestamp = @migration.progress_data['plc_token_requested_at']
    assert_not_nil second_timestamp
    assert second_timestamp != first_timestamp
  end

  test "token expiration checked before other PLC operations" do
    # Set up expired token
    @migration.set_plc_token("expired-token")
    @migration.update!(credentials_expires_at: 1.hour.ago)

    # Mock GoatService - should never be called because expiration check happens first
    service = mock('goat_service')
    service.expects(:get_recommended_plc_operation).never
    service.expects(:sign_plc_operation).never
    service.expects(:submit_plc_operation).never
    GoatService.stubs(:new).returns(service)

    job = UpdatePlcJob.new

    # Should fail on expiration check before attempting any PLC operations
    assert_raises(GoatService::AuthenticationError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert_match(/PLC token has expired/i, @migration.last_error)
  end
end
