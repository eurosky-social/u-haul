class MigrationMailer < ApplicationMailer
  default from: ENV.fetch('MAILER_FROM_EMAIL', 'noreply@eurosky-migration.local')

  def account_password(migration, password)
    @migration = migration
    @password = password
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))

    mail(
      to: migration.email,
      subject: "Your New Account Password for #{migration.new_handle} (#{migration.token})"
    )
  end

  def backup_ready(migration)
    @migration = migration
    @download_url = migration_download_backup_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @expires_at = migration.backup_expires_at
    @backup_size = migration.backup_size

    mail(
      to: migration.email,
      subject: "Your Eurosky Migration Backup is Ready (#{migration.token})"
    )
  end

  def migration_failed(migration)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @error_message = migration.last_error
    @failed_step = migration.current_job_step || migration.status
    @retry_count = migration.retry_count

    mail(
      to: migration.email,
      subject: "Migration Failed - Action Required (#{migration.token})"
    )
  end

  def migration_completed(migration)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @rotation_key_private = migration.rotation_key
    @rotation_key_public = migration.progress_data['rotation_key_public']
    @backup_available = migration.backup_available?
    @download_url = migration_download_backup_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001')) if @backup_available
    @completed_at = migration.progress_data['completed_at']

    mail(
      to: migration.email,
      subject: "✅ Migration Complete - Save Your Rotation Key! (#{migration.token})"
    )
  end

  def plc_otp(migration, otp)
    @migration = migration
    @otp = otp
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @expires_in = '15 minutes'

    mail(
      to: migration.email,
      subject: "PLC Verification Code: #{otp} (#{migration.token})"
    )
  end

  def email_verification(migration)
    @migration = migration
    @verification_url = verify_email_url(token: migration.token, verification_token: migration.email_verification_token, host: ENV.fetch('DOMAIN', 'localhost:3001'))

    mail(
      to: migration.email,
      subject: "Verify your email to start migration (#{migration.token})"
    )
  end

  def critical_plc_failure(migration)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @error_message = migration.last_error
    @rotation_key = migration.rotation_key
    @support_email = ENV.fetch('SUPPORT_EMAIL', 'support@example.com')

    mail(
      to: migration.email,
      subject: "🚨 URGENT: Critical Migration Failure - DO NOT START NEW MIGRATION (#{migration.token})",
      priority: 1 # High priority
    )
  end

  def failed_blobs_retry_complete(migration, successful_count, failed_count)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @successful_count = successful_count
    @failed_count = failed_count
    @can_retry_again = failed_count > 0

    mail(
      to: migration.email,
      subject: "Blob Retry Complete: #{successful_count} succeeded, #{failed_count} still failed (#{migration.token})"
    )
  end
end
