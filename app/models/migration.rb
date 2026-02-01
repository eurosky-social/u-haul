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

  # Prepend the expiration check module AFTER Lockbox has defined its methods
  prepend ExpirationChecks

  # Validations
  validates :did, presence: true, uniqueness: true, format: { with: /\Adid:[a-z0-9]+:[a-z0-9._:\-]+\z/i }
  validates :token, presence: true, uniqueness: true, format: { with: /\AEURO-[A-Z0-9]{8}\z/ }
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :status, presence: true, inclusion: { in: statuses.keys }
  validates :old_pds_host, :new_pds_host, presence: true
  validates :old_handle, :new_handle, presence: true
  validates :retry_count, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :estimated_memory_mb, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  # Validate invite code if required by configuration
  validates :encrypted_invite_code, presence: true, if: -> { EuroskyConfig.invite_code_required? && new_record? }

  # Callbacks
  before_validation :generate_token, on: :create
  before_validation :normalize_hosts
  after_create :schedule_first_job

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
      credentials_expires_at: nil
    )
    Rails.logger.info("Cleared encrypted credentials for migration #{token}")
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

  private

  # Token generation - EURO-XXXXXXXX format
  def generate_token
    return if token.present?

    loop do
      candidate = "EURO-#{SecureRandom.alphanumeric(8).upcase}"
      self.token = candidate
      break unless Migration.exists?(token: candidate)
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
end
