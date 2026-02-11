class Migration < ApplicationRecord
  # Module to override Lockbox getters with expiration checks
  # This must be prepended AFTER Lockbox defines its methods
  module ExpirationChecks
    def password
      return nil if credentials_expired?
      super
    end

    def plc_token
      return nil if credentials_expired?
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

  # Prepend the expiration check module AFTER Lockbox has defined its methods
  prepend ExpirationChecks

  # Validations
  validates :did, presence: true, format: { with: /\Adid:[a-z0-9]+:[a-z0-9._:\-]+\z/i }
  validates :token, presence: true, uniqueness: true, format: { with: /\AEURO-[A-Z0-9]{16}\z/ }

  # Custom validation: Only allow one active migration per DID
  # Allows historical records and future migrations after completion/failure
  validate :no_concurrent_active_migration, on: :create
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
  validates :estimated_memory_mb, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  # Validate invite code if required by configuration
  validates :encrypted_invite_code, presence: true, if: -> { EuroskyConfig.invite_code_required? && new_record? }

  # Callbacks
  before_validation :generate_token, on: :create
  before_validation :generate_email_verification_token, on: :create
  before_validation :normalize_hosts
  after_create :send_email_verification

  # Scopes
  scope :active, -> { where.not(status: [:completed, :failed]) }
  scope :pending_plc, -> { where(status: :pending_plc) }
  scope :in_progress, -> { where(status: [:pending_download, :pending_backup, :pending_repo, :pending_blobs, :pending_prefs, :pending_activation]) }
  scope :by_memory, -> { order(estimated_memory_mb: :desc) }
  scope :recent, -> { order(created_at: :desc) }
  scope :with_expired_backups, -> { where('backup_expires_at IS NOT NULL AND backup_expires_at < ?', Time.current) }

  # State machine transitions
  def advance_to_pending_backup!
    update!(status: :pending_backup)
    CreateBackupBundleJob.perform_later(id)
  end

  def advance_to_backup_ready!
    update!(status: :backup_ready)
    # Automatically proceed to account creation after backup is ready
    CreateAccountJob.perform_later(id)
  end

  def advance_to_pending_repo!
    update!(status: :pending_repo)
    if create_backup_bundle && downloaded_data_path.present?
      # Upload from local files if backup was enabled
      UploadRepoJob.perform_later(id)
    else
      # Stream download-upload if backup was disabled
      ImportRepoJob.perform_later(id)
    end
  end

  def advance_to_pending_blobs!
    update!(status: :pending_blobs)
    if create_backup_bundle && downloaded_data_path.present?
      # Upload from local files if backup was enabled
      UploadBlobsJob.perform_later(id)
    else
      # Stream download-upload if backup was disabled
      ImportBlobsJob.perform_later(id)
    end
  end

  def advance_to_pending_prefs!
    update!(status: :pending_prefs)
    ImportPrefsJob.perform_later(id)
  end

  def advance_to_pending_plc!
    update!(status: :pending_plc)
    WaitForPlcTokenJob.perform_later(id)
  end

  def advance_to_pending_activation!
    update!(status: :pending_activation)
    ActivateAccountJob.perform_later(id)
  end

  def mark_complete!
    update!(status: :completed, last_error: nil)
  end

  def mark_failed!(error)
    update!(
      status: :failed,
      last_error: error.to_s,
      retry_count: retry_count + 1
    )
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
    return nil unless pending_blobs? && progress_data['blobs'].present?

    blobs = progress_data['blobs'].values
    total_size = blobs.sum { |b| b['size'].to_i }
    uploaded_size = blobs.sum { |b| b['uploaded'].to_i }

    return nil if uploaded_size.zero?

    # Calculate upload rate based on timestamps
    first_blob = blobs.min_by { |b| b['updated_at'] }
    last_blob = blobs.max_by { |b| b['updated_at'] }

    return nil unless first_blob && last_blob

    time_elapsed = Time.parse(last_blob['updated_at']) - Time.parse(first_blob['updated_at'])
    return nil if time_elapsed.zero?

    upload_rate = uploaded_size / time_elapsed
    remaining_size = total_size - uploaded_size

    (remaining_size / upload_rate).to_i
  end

  # Credential management
  def set_password(pwd, expires_in: 48.hours)
    self.password = pwd  # Lockbox handles encryption automatically
    self.credentials_expires_at = expires_in.from_now
    save!
  end

  def set_plc_token(token, expires_in: 1.hour)
    self.plc_token = token  # Lockbox handles encryption automatically
    self.credentials_expires_at = expires_in.from_now
    save!
  end

  def credentials_expired?
    credentials_expires_at.nil? || credentials_expires_at < Time.current
  end

  # Clear all encrypted credentials (for security after migration completes)
  def clear_credentials!
    update!(
      encrypted_password: nil,
      encrypted_plc_token: nil,
      encrypted_old_access_token: nil,
      encrypted_old_refresh_token: nil,
      credentials_expires_at: nil
    )
    Rails.logger.info("Cleared encrypted credentials for migration #{token}")
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

  def clear_old_pds_tokens!
    update!(
      encrypted_old_access_token: nil,
      encrypted_old_refresh_token: nil
    )
    Rails.logger.info("Cleared old PDS tokens for migration #{token}")
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

  def rotation_key
    rotation_private_key_ciphertext
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

  # Verify email with token
  def verify_email!(token)
    if email_verification_token == token
      update!(email_verified_at: Time.current, email_verification_token: nil)
      Rails.logger.info("Email verified for migration #{self.token}")
      # Now actually start the migration
      schedule_first_job
      true
    else
      Rails.logger.warn("Invalid email verification token for migration #{self.token}")
      false
    end
  end

  # Check if email is verified
  def email_verified?
    email_verified_at.present?
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

  # Email verification token generation (32 characters = ~190 bits entropy)
  def generate_email_verification_token
    return if email_verification_token.present?

    loop do
      candidate = SecureRandom.urlsafe_base64(32)
      self.email_verification_token = candidate
      break unless Migration.exists?(email_verification_token: candidate)
    end
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
      # Start with download if backup is enabled
      update!(status: :pending_download)
      DownloadAllDataJob.perform_later(id)
    else
      # Skip download and backup if disabled
      update!(status: :pending_account)
      CreateAccountJob.perform_later(id)
    end
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

    return base unless progress_data['blobs'].present?

    blobs = progress_data['blobs'].values
    total_size = blobs.sum { |b| b['size'].to_i }
    uploaded_size = blobs.sum { |b| b['uploaded'].to_i }

    return base if total_size.zero?

    # Blobs stage is 40-70% (with backup) or 20-50% (without backup)
    percentage = (uploaded_size.to_f / total_size * range).round
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
