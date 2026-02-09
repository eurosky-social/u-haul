# Be sure to restart your server when you modify this file.
#
# Lockbox encryption configuration for sensitive data
#
# Provides transparent encryption/decryption for encrypted attributes
# such as passwords and PLC tokens

require 'lockbox'

# Set up Lockbox master key from environment
# Lockbox will automatically use this for encrypting attributes
#
# SECURITY: In production, ALWAYS use a dedicated LOCKBOX_MASTER_KEY
# Do NOT derive from SECRET_KEY_BASE, as rotating SECRET_KEY_BASE
# would make all encrypted data undecryptable.
if ENV['LOCKBOX_MASTER_KEY'].present?
  # Use dedicated Lockbox master key if provided (already in correct format)
  # LOCKBOX_MASTER_KEY should be 32 bytes hex-encoded (64 hex chars)
  # Generate with: openssl rand -hex 32
  ENV['LOCKBOX_MASTER_KEY']
  Rails.logger.info("Lockbox: Using dedicated LOCKBOX_MASTER_KEY")
elsif Rails.env.production?
  # Production REQUIRES dedicated key - do not fall back to SECRET_KEY_BASE
  raise "PRODUCTION SECURITY ERROR: LOCKBOX_MASTER_KEY environment variable is required in production. " \
        "Generate with: openssl rand -hex 32"
elsif Rails.env.test?
  # Test environment fallback - generate a deterministic key for testing
  require 'digest/sha2'
  ENV['LOCKBOX_MASTER_KEY'] = Digest::SHA256.hexdigest('test_lockbox_master_key')
elsif Rails.env.development?
  # Development fallback - generate a warning key
  require 'digest/sha2'
  ENV['LOCKBOX_MASTER_KEY'] = Digest::SHA256.hexdigest('dev_lockbox_master_key')
  Rails.logger.warn("Lockbox: Using generated development key. Set LOCKBOX_MASTER_KEY for persistent encryption.")
else
  raise "Lockbox encryption requires LOCKBOX_MASTER_KEY to be set"
end

Rails.logger.debug("Lockbox initialized for attribute encryption")
