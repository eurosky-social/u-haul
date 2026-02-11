require "test_helper"

# MigrationErrorHelper PLC Token Expiration Tests
# Tests for PLC token expired error context generation
class MigrationErrorHelperPlcTest < ActiveSupport::TestCase
  def setup
    @migration = migrations(:pending_migration)
    @migration.update!(
      status: :failed,
      old_pds_host: 'https://oldpds.example.com',
      new_pds_host: 'https://newpds.example.com',
      credentials_expires_at: 1.hour.ago,
      last_error: "PLC token has expired (expired at: #{1.hour.ago}). Please request a new token."
    )
  end

  # ============================================================================
  # Error Type Detection
  # ============================================================================

  test "detect_error_type identifies PLC token expired error" do
    error_message = "PLC token has expired (expired at: 2026-02-11 20:00:00 UTC). Please request a new token."
    error_type = MigrationErrorHelper.detect_error_type(error_message)
    assert_equal :plc_token_expired, error_type
  end

  test "detect_error_type distinguishes PLC token expiration from general credential expiration" do
    plc_error = "PLC token has expired"
    general_error = "credentials expired"

    assert_equal :plc_token_expired, MigrationErrorHelper.detect_error_type(plc_error)
    assert_equal :credentials_expired, MigrationErrorHelper.detect_error_type(general_error)
  end

  # ============================================================================
  # Error Context Generation
  # ============================================================================

  test "plc_token_expired_context generates appropriate error context" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert_not_nil context
    assert_equal :warning, context[:severity]
    assert_equal "⏰", context[:icon]
    assert_equal "PLC Token Expired", context[:title]
    assert_match(/PLC operation token.*expired/i, context[:what_happened])
    assert_match(/only valid for 1 hour/i, context[:what_happened])
    assert_equal "Migration paused - new PLC token required", context[:current_status]
  end

  test "plc_token_expired_context includes actionable steps" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert context[:what_to_do].is_a?(Array)
    assert context[:what_to_do].any? { |step| step.include?("Request New PLC Token") }
    assert context[:what_to_do].any? { |step| step.include?(@migration.old_pds_host) }
    assert context[:what_to_do].any? { |step| step.include?("within 1 hour") }
    assert context[:what_to_do].any? { |step| step.include?("migration data is safe") }
  end

  test "plc_token_expired_context sets show_request_new_plc_token flag" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert context[:show_request_new_plc_token]
    assert_not context[:show_retry_button]
    assert_not context[:show_new_migration_button]
  end

  test "plc_token_expired_context includes technical details" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert_equal @migration.last_error, context[:technical_details]
    assert_equal @migration.credentials_expires_at, context[:expired_at]
    assert_equal @migration.old_pds_host, context[:old_pds_host]
  end

  test "plc_token_expired_context includes help link" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert_equal "/docs/troubleshooting#plc-token-expiration", context[:help_link]
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  test "explain_error returns nil when no error present" do
    @migration.update!(last_error: nil)
    context = MigrationErrorHelper.explain_error(@migration)

    assert_nil context
  end

  test "plc_token_expired_context handles missing old_pds_host gracefully" do
    @migration.update!(old_pds_host: nil)
    context = MigrationErrorHelper.explain_error(@migration)

    assert_not_nil context
    # Should not raise error, even with nil old_pds_host
    assert context[:what_to_do].any? { |step| step.is_a?(String) }
  end
end
