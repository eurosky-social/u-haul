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
end
