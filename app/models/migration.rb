class Migration < ApplicationRecord
  # Raised by advance_with_job! / abort_if_terminal! when a job discovers that
  # the migration was cancelled, failed, completed or deleted underneath it.
  # Jobs rescue this first and stop: no retry, no further writes to the row.
  class Aborted < StandardError; end

  TERMINAL_STATUSES = %w[completed failed].freeze

  # Module to override Lockbox getters with expiration checks
  # This must be prepended AFTER Lockbox defines its methods
  module ExpirationChecks
    def password
      return nil if credentials_expired?
      super
    end

    def plc_token
      return nil if plc_token_expired?
      super
    end

    def invite_code
      return nil if invite_code_expired?
      super
    end

    def old_access_token
      return nil if credentials_expired?
      super
    end

    def old_refresh_token
      return nil if credentials_expired?
      super
    end

    def new_access_token
      return nil if credentials_expired?
      super
    end

    def new_refresh_token
      return nil if credentials_expired?
      super
    end
  end
  # Enums
  enum :status, {
    pending_download: 'pending_download',
    pending_backup: 'pending_backup',
    backup_ready: 'backup_ready',
    pending_account: 'pending_account',
    account_created: 'account_created',
    pending_repo: 'pending_repo',
    pending_blobs: 'pending_blobs',
    pending_prefs: 'pending_prefs',
    pending_plc: 'pending_plc',
    pending_activation: 'pending_activation',
    completed: 'completed',
    failed: 'failed'
  }, validate: true

  enum :migration_type, {
    migration_out: 'migration_out',  # Migrating TO a new PDS (create new account)
    migration_in: 'migration_in'     # Migrating back to existing PDS (login only)
  }, validate: true

  # Encryption for sensitive fields using Lockbox
  # Provide the master key as a 64-character hex string, decoded to 32 bytes
  # Lockbox requires a 32-byte binary key
  lockbox_key = lambda do
    key_hex = ENV.fetch('LOCKBOX_MASTER_KEY') { Digest::SHA256.hexdigest('fallback_key_for_dev') }
    [key_hex].pack('H*')  # Decode hex string to 32 bytes of binary data
  end

  has_encrypted :password, key: lockbox_key, encrypted_attribute: :encrypted_password
  has_encrypted :plc_token, key: lockbox_key, encrypted_attribute: :encrypted_plc_token
  has_encrypted :invite_code, key: lockbox_key, encrypted_attribute: :encrypted_invite_code
  has_encrypted :rotation_key, key: lockbox_key, encrypted_attribute: :rotation_private_key_ciphertext
  has_encrypted :plc_otp, key: lockbox_key, encrypted_attribute: :encrypted_plc_otp
  has_encrypted :old_access_token, key: lockbox_key, encrypted_attribute: :encrypted_old_access_token
  has_encrypted :old_refresh_token, key: lockbox_key, encrypted_attribute: :encrypted_old_refresh_token
  has_encrypted :new_access_token, key: lockbox_key, encrypted_attribute: :encrypted_new_access_token
  has_encrypted :new_refresh_token, key: lockbox_key, encrypted_attribute: :encrypted_new_refresh_token

  # Prepend the expiration check module AFTER Lockbox has defined its methods
  prepend ExpirationChecks

  # Validations
  validates :did, presence: true, format: { with: /\Adid:[a-z0-9]+:[a-z0-9._:\-]+\z/i }
  validates :token, presence: true, uniqueness: true, format: { with: /\AEURO-[A-Z0-9]{16}\z/ }

  # Custom validation: Only allow one active migration per DID
  # Allows historical records and future migrations after completion/failure
  validate :no_concurrent_active_migration, on: :create
  validate :global_migration_capacity_available, on: :create
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :status, presence: true, inclusion: { in: Migration.statuses.keys }
  validates :old_pds_host, :new_pds_host, presence: true

  # ATProto handle validation (official spec from https://atproto.com/specs/handle)
  # Format: Handles must be valid DNS hostnames with at least one dot
  # Each label: 1-63 alphanumeric chars (can include hyphens, but not at start/end)
  validates :old_handle, :new_handle, presence: true,
    format: {
      with: /\A([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/,
      message: "must be a valid ATProto handle (e.g., user.bsky.social)"
    },
    length: { maximum: 253 }

  # PDS host URL validation with SSRF protection
  # validate :validate_pds_hosts
  validates :retry_count, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  # Validate invite code if required by configuration
  validates :encrypted_invite_code, presence: true, if: -> { EuroskyConfig.invite_code_required? && new_record? && !migration_in? }

  # Callbacks
  before_validation :generate_token, on: :create
  before_validation :generate_email_verification_token, on: :create
  before_validation :set_locale, on: :create
  before_validation :normalize_hosts
  after_create_commit :send_email_verification

  # Scopes
  # Global migration capacity limit (configurable via env var).
  # This is intentionally high — blob transfers run with 5 threads per
  # migration and no global limit, so all users make progress simultaneously.
  # This limit only exists to prevent abuse (e.g. scripted mass submissions).
  MAX_CONCURRENT_MIGRATIONS = ENV.fetch('MAX_CONCURRENT_MIGRATIONS', 100).to_i

  scope :active, -> { where.not(status: [:completed, :failed]) }
  scope :pending_plc, -> { where(status: :pending_plc) }
  scope :in_progress, -> { where(status: [:pending_download, :pending_backup, :pending_repo, :pending_blobs, :pending_prefs, :pending_activation]) }
  scope :recent, -> { order(created_at: :desc) }
  scope :with_expired_backups, -> { where('backup_expires_at IS NOT NULL AND backup_expires_at < ?', Time.current) }

  # State machine transitions
  #
  # All advance_to_* methods use advance_with_job! to ensure atomicity:
  # if the job enqueue fails (e.g., Redis hiccup), the status is reverted
  # so the calling job's retry can re-attempt from the correct state.
  def advance_to_pending_backup!
    advance_with_job!(:pending_backup) { CreateBackupBundleJob.perform_later(id) }
  end

  def advance_to_backup_ready!
    advance_with_job!(:backup_ready) { CreateAccountJob.perform_later(id) }
  end

  def advance_to_pending_repo!
    advance_with_job!(:pending_repo) do
      if create_backup_bundle && downloaded_data_path.present?
        UploadRepoJob.perform_later(id)
      else
        ImportRepoJob.perform_later(id)
      end
    end
  end

  def advance_to_pending_blobs!
    advance_with_job!(:pending_blobs) do
      if create_backup_bundle && downloaded_data_path.present?
        UploadBlobsJob.perform_later(id)
      else
        ImportBlobsJob.perform_later(id)
      end
    end
  end

  def advance_to_pending_prefs!
    advance_with_job!(:pending_prefs) { ImportPrefsJob.perform_later(id) }
  end

  def advance_to_pending_plc!
    advance_with_job!(:pending_plc) { WaitForPlcTokenJob.perform_later(id) }
  end

  def advance_to_pending_activation!
    advance_with_job!(:pending_activation) { ActivateAccountJob.perform_later(id) }
  end

  def mark_complete!
    update!(status: :completed, last_error: nil, error_code: nil)
  end

  def mark_failed!(error, error_code: nil)
    update!(
      status: :failed,
      last_error: error.to_s,
      error_code: error_code&.to_s,
      retry_count: retry_count + 1
    )

    # Send re-authentication email for auth/credential failures.
    # CRITICAL PLC failures have their own dedicated email — skip those.
    should_send_reauth = if error_code
      [:credentials_need_reauth, :authentication].include?(error_code.to_sym)
    else
      # Fallback to regex for callers that don't pass error_code
      error.to_s.match?(/authentication error|credentials expired/i) && !error.to_s.start_with?("CRITICAL:")
    end
    MigrationMailer.reauthentication_required(self).deliver_later rescue nil if should_send_reauth
  end

  # True when the row is failed/completed in the database. Reads only the status
  # column so unsaved in-memory changes on this object are kept. A row that
  # cannot be seen is NOT treated as terminal: jobs start with Migration.find,
  # so a deleted record never gets this far, whereas a worker thread on its own
  # connection legitimately cannot see a row inside a transactional test.
  def terminal_in_db?
    db_status = self.class.where(id: id).pick(:status)
    TERMINAL_STATUSES.include?(db_status)
  end

  # Long-running jobs call this between batches so a cancellation stops them.
  def abort_if_terminal!
    return unless terminal_in_db?

    raise Aborted, "Migration #{token} was cancelled, failed or completed; stopping job"
  end

  # Merge keys into progress_data with one atomic UPDATE. Touches nothing but
  # progress_data/updated_at and keeps keys written by other processes (for
  # example cancelled_at), unlike assigning the whole hash and calling save!.
  # The in-memory copy is updated too so a later save! does not drop the keys.
  def merge_progress!(patch)
    patch = patch.stringify_keys
    self.class.where(id: id).update_all([
      "progress_data = COALESCE(progress_data, '{}'::jsonb) || ?::jsonb, updated_at = ?",
      patch.to_json, Time.current
    ])
    self.progress_data = (progress_data || {}).merge(patch)
  end

  # Whether this migration can be cancelled by the user.
  # Cancellation is allowed before the PLC operation is submitted (point of no return).
  # Once the user submits the PLC token and UpdatePlcJob is running, cancellation
  # is no longer safe — the PLC directory could be modified at any moment.
  def cancellable?
    return false if completed? || failed? || pending_activation?
    return false if progress_data&.dig('plc_operation_submitted_at').present?
    return false if encrypted_plc_token.present? && !plc_token_expired?
    true
  end

  # Job retry tracking
  def start_job_attempt!(job_name, max_attempts, attempt_number = 1)
    update!(
      current_job_step: job_name,
      current_job_attempt: attempt_number,
      current_job_max_attempts: max_attempts
    )
  end

  def increment_job_attempt!
    update!(current_job_attempt: current_job_attempt + 1)
  end

  def clear_job_tracking!
    update!(
      current_job_step: nil,
      current_job_attempt: 0,
      current_job_max_attempts: 3
    )
  end

  def job_attempts_remaining
    return nil unless current_job_max_attempts && current_job_attempt
    current_job_max_attempts - current_job_attempt
  end

  def job_retrying?
    current_job_attempt.to_i > 1
  end

  # Progress tracking
  def update_blob_progress!(cid:, size:, uploaded:)
    progress_data['blobs'] ||= {}
    progress_data['blobs'][cid] = {
      'size' => size,
      'uploaded' => uploaded,
      'updated_at' => Time.current.iso8601
    }
    save!
  end

  def progress_percentage
    case status
    when 'pending_download'
      download_percentage
    when 'pending_backup'
      15
    when 'backup_ready'
      20
    when 'pending_account'
      create_backup_bundle ? 25 : 0
    when 'account_created'
      create_backup_bundle ? 30 : 10
    when 'pending_repo'
      create_backup_bundle ? 35 : 20
    when 'pending_blobs'
      blob_upload_percentage
    when 'pending_prefs'
      70
    when 'pending_plc'
      80
    when 'pending_activation'
      90
    when 'completed'
      100
    when 'failed'
      0
    else
      0
    end
  end

  def estimated_time_remaining
    return nil unless pending_blobs?

    completed = (progress_data['blobs_completed'] || progress_data['blobs_uploaded']).to_i
    total = progress_data['blobs_total'].to_i
    started_at = progress_data['blobs_started_at']

    return nil if completed.zero? || total.zero? || started_at.blank?

    time_elapsed = Time.current - Time.parse(started_at)
    return nil if time_elapsed.zero?

    rate = completed.to_f / time_elapsed # blobs per second
    remaining = total - completed

    (remaining / rate).to_i
  end

  # Credential management
  def set_password(pwd, expires_in: 48.hours)
    self.password = pwd  # Lockbox handles encryption automatically
    self.credentials_expires_at = expires_in.from_now
    save!
  end

  def set_plc_token(token, expires_in: 1.hour)
    self.plc_token = token  # Lockbox handles encryption automatically
    # Store PLC token expiry separately in progress_data so it doesn't
    # overwrite credentials_expires_at (which governs old PDS token access)
    self.progress_data ||= {}
    self.progress_data['plc_token_expires_at'] = expires_in.from_now.iso8601
    save!
  end

  def credentials_expired?
    credentials_expires_at.nil? || credentials_expires_at < Time.current
  end

  # PLC token has its own expiry (1 hour) separate from old PDS credentials (48 hours)
  def plc_token_expired?
    plc_expires = progress_data&.dig('plc_token_expires_at')
    return true if plc_expires.nil?

    Time.parse(plc_expires) < Time.current
  end

  # Clear all encrypted credentials (for security after migration completes)
  def clear_credentials!
    update!(
      encrypted_password: nil,
      encrypted_plc_token: nil,
      encrypted_old_access_token: nil,
      encrypted_old_refresh_token: nil,
      encrypted_new_access_token: nil,
      encrypted_new_refresh_token: nil,
      credentials_expires_at: nil
    )
    Rails.logger.info("Cleared encrypted credentials for migration #{token}")
  end

  # Clear non-essential data after migration completes.
  # Keeps only what the user needs on the completion page:
  # email, rotation_key, token, handles, PDS hosts, status, backup info, migration_type
  def clear_non_essential_data!
    update!(
      encrypted_plc_otp: nil,
      encrypted_invite_code: nil,
      invite_code_expires_at: nil,
      last_error: nil,
      error_code: nil,
      current_job_step: nil,
      current_job_attempt: 0,
      current_job_max_attempts: 3,
      retry_count: 0
    )
    Rails.logger.info("Cleared non-essential data for migration #{token}")
  end

  # Old PDS token management
  def set_old_pds_tokens!(access_token:, refresh_token:, expires_in: 48.hours)
    self.old_access_token = access_token
    self.old_refresh_token = refresh_token
    self.credentials_expires_at = expires_in.from_now
    save!
  end

  def update_old_pds_tokens!(access_token:, refresh_token:)
    self.old_access_token = access_token
    self.old_refresh_token = refresh_token
    save!
  end

  def has_old_pds_tokens?
    encrypted_old_refresh_token.present? && !credentials_expired?
  end

  def clear_old_pds_tokens!
    update!(
      encrypted_old_access_token: nil,
      encrypted_old_refresh_token: nil
    )
    Rails.logger.info("Cleared old PDS tokens for migration #{token}")
  end

  # New (target) PDS token management — used for migration_in when the user
  # authenticates against their existing account on the target PDS (e.g. bsky.social)
  def set_new_pds_tokens!(access_token:, refresh_token:)
    self.new_access_token = access_token
    self.new_refresh_token = refresh_token
    save!
  end

  def update_new_pds_tokens!(access_token:, refresh_token:)
    self.new_access_token = access_token
    self.new_refresh_token = refresh_token
    save!
  end

  def has_new_pds_tokens?
    encrypted_new_refresh_token.present?
  end

  # Invite code management
  def set_invite_code(code)
    self.invite_code = code  # Lockbox handles encryption automatically
    self.invite_code_expires_at = 48.hours.from_now
    save!
  end

  def invite_code_expired?
    invite_code_expires_at.nil? || invite_code_expires_at < Time.current
  end

  # Rotation key management
  def set_rotation_key(private_key)
    self.rotation_key = private_key  # Lockbox handles encryption automatically
    save!
  end

  # Backup bundle management
  def set_backup_bundle_path(path)
    self.backup_bundle_path = path
    self.backup_created_at = Time.current
    self.backup_expires_at = 24.hours.from_now
    save!
  end

  def backup_expired?
    backup_expires_at.nil? || backup_expires_at < Time.current
  end

  def backup_available?
    backup_bundle_path.present? &&
      File.exist?(backup_bundle_path) &&
      !backup_expired?
  end

  def backup_size
    return nil unless backup_available?
    File.size(backup_bundle_path)
  end

  def cleanup_backup!
    return unless backup_bundle_path.present?

    # Delete the bundle file
    FileUtils.rm_f(backup_bundle_path) if File.exist?(backup_bundle_path)

    # Clear the path
    update!(backup_bundle_path: nil, backup_expires_at: nil)
  end

  def cleanup_downloaded_data!
    return unless downloaded_data_path.present?

    # Delete the downloaded data directory
    FileUtils.rm_rf(downloaded_data_path) if Dir.exist?(downloaded_data_path)

    # Clear the path
    update!(downloaded_data_path: nil)
  end

  # Migration Type Helpers

  def migrating_to_new_pds?
    migration_out?
  end

  def returning_to_existing_pds?
    migration_in?
  end

  # Verify email with code (XXX-XXX format, case-insensitive)
  def verify_email!(code)
    if email_verification_token.present? && email_verification_token.upcase == code.to_s.strip.upcase
      update!(email_verified_at: Time.current, email_verification_token: nil)
      Rails.logger.info("Email verified for migration #{self.token}")
      if pending_account?
        # Normal case: nothing has run yet
        schedule_first_job
      elsif completed? || pending_activation? || progress_data&.dig('plc_operation_submitted_at').present?
        # Past the point of no return - never restart
        Rails.logger.warn("Migration #{self.token} verified at status '#{status}' after the PLC step; not restarting")
      else
        # Advanced without verification by an older sweeper, or failed before
        # verification. Restart from the top so the transferred data is fresh
        # (the user may have kept posting in the meantime). CreateAccountJob
        # recognises the account this migration created earlier and continues.
        Rails.logger.warn("Migration #{self.token} verified at status '#{status}'; restarting the pipeline from the beginning")
        update!(status: :pending_account, last_error: nil, error_code: nil, current_job_attempt: 0)
        schedule_first_job
      end
      true
    else
      Rails.logger.warn("Invalid email verification code for migration #{self.token}")
      false
    end
  end

  # Check if email is verified
  def email_verified?
    email_verified_at.present?
  end

  # Regenerate verification code and persist (for resend)
  def regenerate_email_verification_token!
    self.email_verification_token = nil
    generate_email_verification_token
    save!
  end

  private

  # Token generation - EURO-XXXXXXXXXXXXXXXX format (16 chars = ~47 bits entropy)
  # Uses SecureRandom for cryptographically secure token generation
  # 16 alphanumeric characters = 62^16 = ~47 bits of entropy (sufficient for these tokens)
  def generate_token
    return if token.present?

    loop do
      # Generate 16 uppercase alphanumeric characters (A-Z, 0-9 only)
      random_part = Array.new(16) { [*'A'..'Z', *'0'..'9'].sample }.join
      candidate = "EURO-#{random_part}"
      self.token = candidate
      break unless Migration.exists?(token: candidate)
    end
  end

  # Email verification code generation (XXX-XXX format, ~30 bits entropy)
  # Short human-readable code that the user enters manually on the status page.
  # This avoids issues with email link scanners auto-loading verification URLs.
  def generate_email_verification_token
    return if email_verification_token.present?

    chars = [*'A'..'Z', *'0'..'9']
    loop do
      candidate = "#{Array.new(3) { chars.sample }.join}-#{Array.new(3) { chars.sample }.join}"
      self.email_verification_token = candidate
      break unless Migration.exists?(email_verification_token: candidate)
    end
  end

  # Store the user's locale at migration creation time
  def set_locale
    self.locale ||= I18n.locale.to_s
  end

  # Normalize PDS hosts to include https:// prefix
  def normalize_hosts
    self.old_pds_host = normalize_url(old_pds_host) if old_pds_host.present?
    self.new_pds_host = normalize_url(new_pds_host) if new_pds_host.present?
  end

  def normalize_url(url)
    return url if url.blank?
    return url if url.start_with?('http://', 'https://')
    "https://#{url}"
  end

  def send_email_verification
    # Send email verification instead of starting migration immediately
    MigrationMailer.email_verification(self).deliver_later
    Rails.logger.info("Email verification sent for migration #{token}")
  end

  def schedule_first_job
    if create_backup_bundle
      advance_with_job!(:pending_download) { DownloadAllDataJob.perform_later(id) }
    else
      advance_with_job!(:pending_account) { CreateAccountJob.perform_later(id) }
    end
  end

  # Atomically advance status and enqueue the next job.
  # If the enqueue fails (e.g., Redis connection error), the status is
  # reverted so the calling job's retry mechanism can re-attempt from
  # the correct state instead of skipping via idempotency check.
  def advance_with_job!(new_status)
    previous_status = status

    # Only advance when the row still has the status this process last saw.
    # A cancellation (mark_failed!) or a competing job may have changed it in
    # the meantime; overwriting that silently resurrected cancelled migrations
    # (status back to pending_*, error_code still "cancelled").
    transaction do
      db_status = self.class.lock.where(id: id).pick(:status)
      if db_status != previous_status
        raise Aborted, "Migration #{token} is '#{db_status || 'deleted'}' in the database " \
                       "(this job expected '#{previous_status}'); not advancing to #{new_status}"
      end
      update!(status: new_status)
    end

    yield
  rescue Aborted
    raise
  rescue => e
    Rails.logger.error(
      "[Migration] Failed to enqueue job after advancing #{token} to #{new_status}: #{e.message}. " \
      "Reverting status to #{previous_status}."
    )
    update!(status: previous_status)
    raise
  end


  # Helper for download percentage calculation
  def download_percentage
    return 0 unless progress_data['download_progress'].present?

    progress = progress_data['download_progress']
    downloaded = progress['downloaded'].to_i
    total = progress['total'].to_i

    return 0 if total.zero?

    # Download stage is 0-10% of total progress
    ((downloaded.to_f / total) * 10).round
  end

  # Helper for blob upload percentage calculation
  def blob_upload_percentage
    base = create_backup_bundle ? 40 : 20
    range = 30

    completed = (progress_data['blobs_completed'] || progress_data['blobs_uploaded']).to_i
    total = progress_data['blobs_total'].to_i

    return base if total.zero?

    # Blobs stage is 40-70% (with backup) or 20-50% (without backup)
    percentage = (completed.to_f / total * range).round
    base + percentage
  end

  def retry_from_current_step!
    return false unless failed? || error?

    job_class = case current_step
    when 'creating_account', nil then CreateAccountJob
    when 'importing_repo' then ImportRepoJob
    when 'importing_blobs' then ImportBlobsJob
    when 'importing_prefs' then ImportPrefsJob
    when 'waiting_for_token' then WaitForPlcTokenJob
    when 'updating_plc' then UpdatePlcJob
    when 'activating_account' then ActivateAccountJob
    else
      return false
    end

    update(status: 'pending', error_message: nil)
    job_class.perform_async(id)
    true
  end

  # Prevent creating multiple active migrations for the same DID
  # Completed/failed migrations don't block new migrations
  def no_concurrent_active_migration
    return unless did.present?

    active_statuses = Migration.statuses.keys - ['completed', 'failed']

    if Migration.where(did: did)
               .where(status: active_statuses)
               .where.not(id: id)
               .exists?
      errors.add(:did, "already has an active migration in progress. Please wait for it to complete or fail before starting a new migration.")
    end
  end

  # Prevent accepting new migrations when the system is at capacity.
  # Only counts migrations that are actually consuming resources (running jobs).
  # Migrations parked at pending_plc (waiting for user email action) use zero
  # resources and are excluded from this check.
  def global_migration_capacity_available
    if Migration.in_progress.count >= MAX_CONCURRENT_MIGRATIONS
      errors.add(:base, "The migration service is currently at capacity (#{MAX_CONCURRENT_MIGRATIONS} active migrations). " \
        "Please try again in a few minutes.")
    end
  end

  # Validate PDS hosts to prevent SSRF attacks
  def validate_pds_hosts
    [old_pds_host, new_pds_host].each do |host|
      next if host.blank?

      begin
        uri = URI.parse(host)

        # Must use HTTPS
        unless uri.scheme == 'https'
          errors.add(:base, "PDS host must use HTTPS: #{host}")
          next
        end

        # Block localhost and private IPs
        if ['localhost', '127.0.0.1', '::1', '0.0.0.0'].include?(uri.host)
          errors.add(:base, "PDS host cannot be localhost: #{host}")
          next
        end

        # Check for private IP ranges (requires resolving hostname)
        begin
          require 'resolv'
          ip = Resolv.getaddress(uri.host)
          ip_addr = IPAddr.new(ip)

          # Block private IP ranges (RFC 1918, loopback, link-local, etc.)
          private_ranges = [
            IPAddr.new('10.0.0.0/8'),      # Private
            IPAddr.new('172.16.0.0/12'),   # Private
            IPAddr.new('192.168.0.0/16'),  # Private
            IPAddr.new('127.0.0.0/8'),     # Loopback
            IPAddr.new('169.254.0.0/16'),  # Link-local
            IPAddr.new('::1/128'),         # IPv6 loopback
            IPAddr.new('fc00::/7'),        # IPv6 private
            IPAddr.new('fe80::/10')        # IPv6 link-local
          ]

          if private_ranges.any? { |range| range.include?(ip_addr) }
            errors.add(:base, "PDS host resolves to private IP: #{host}")
            next
          end
        rescue Resolv::ResolvError, SocketError
          # DNS resolution failed - could be temporary, allow it
          # The actual connection will fail if the host doesn't exist
          Rails.logger.warn("Could not resolve PDS host for SSRF check: #{host}")
        end

      rescue URI::InvalidURIError => e
        errors.add(:base, "Invalid PDS host URL: #{host}")
      end
    end
  end
end
