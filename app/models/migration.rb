class Migration < ApplicationRecord
  # Enums
  enum :status, {
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

  # Encryption for sensitive fields
  encrypts :encrypted_password
  encrypts :encrypted_plc_token
  encrypts :encrypted_invite_code

  # Validations
  validates :did, presence: true, uniqueness: true, format: { with: /\Adid:[a-z0-9:]+\z/i }
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
  scope :in_progress, -> { where(status: [:pending_repo, :pending_blobs, :pending_prefs, :pending_activation]) }
  scope :by_memory, -> { order(estimated_memory_mb: :desc) }
  scope :recent, -> { order(created_at: :desc) }

  # State machine transitions
  def advance_to_pending_repo!
    update!(status: :pending_repo)
    ImportRepoJob.perform_later(self)
  end

  def advance_to_pending_blobs!
    update!(status: :pending_blobs)
    ImportBlobsJob.perform_later(self)
  end

  def advance_to_pending_prefs!
    update!(status: :pending_prefs)
    ImportPrefsJob.perform_later(self)
  end

  def advance_to_pending_plc!
    update!(status: :pending_plc)
    WaitForPlcTokenJob.perform_later(self)
  end

  def advance_to_pending_activation!
    update!(status: :pending_activation)
    ActivateAccountJob.perform_later(self)
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
    when 'pending_account'
      0
    when 'account_created'
      10
    when 'pending_repo'
      20
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
  def set_password(password)
    self.encrypted_password = password
    self.credentials_expires_at = 48.hours.from_now
    save!
  end

  def set_plc_token(token)
    self.encrypted_plc_token = token
    self.credentials_expires_at = 1.hour.from_now
    save!
  end

  def password
    return nil if credentials_expired?
    encrypted_password
  end

  def plc_token
    return nil if credentials_expired?
    encrypted_plc_token
  end

  def credentials_expired?
    credentials_expires_at.nil? || credentials_expires_at < Time.current
  end

  # Invite code management
  def set_invite_code(code)
    self.encrypted_invite_code = code
    self.invite_code_expires_at = 48.hours.from_now
    save!
  end

  def invite_code
    return nil if invite_code_expired?
    encrypted_invite_code
  end

  def invite_code_expired?
    invite_code_expires_at.nil? || invite_code_expires_at < Time.current
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
    CreateAccountJob.perform_later(self)
  end

  # Helper for blob upload percentage calculation
  def blob_upload_percentage
    return 20 unless progress_data['blobs'].present?

    blobs = progress_data['blobs'].values
    total_size = blobs.sum { |b| b['size'].to_i }
    uploaded_size = blobs.sum { |b| b['uploaded'].to_i }

    return 20 if total_size.zero?

    # Blobs stage is 20-70% of total progress
    base = 20
    range = 50
    percentage = (uploaded_size.to_f / total_size * range).round
    base + percentage
  end
end
