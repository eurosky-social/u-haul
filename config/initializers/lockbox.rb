# Be sure to restart your server when you modify this file.
#
# Lockbox encryption configuration for sensitive data
#
# Provides transparent encryption/decryption for encrypted attributes
# such as passwords and PLC tokens

require 'lockbox'

# Set up Lockbox master key from environment
# Lockbox will automatically use this for encrypting attributes
if ENV['LOCKBOX_MASTER_KEY'].present?
  # Use dedicated Lockbox master key if provided
  ENV['LOCKBOX_MASTER_KEY']
elsif ENV['SECRET_KEY_BASE'].present?
  # Derive a Lockbox key from Rails SECRET_KEY_BASE
  # SECRET_KEY_BASE is hex-encoded, so we need 32 hex chars = 16 bytes
  ENV['LOCKBOX_MASTER_KEY'] = ENV['SECRET_KEY_BASE'][0, 32]
elsif !Rails.env.production?
  # Development fallback - warn about temporary key
  Rails.logger.warn("Lockbox: Using SECRET_KEY_BASE for encryption. Set LOCKBOX_MASTER_KEY for persistent encryption.")
else
  # Production requires explicit key
  raise "Lockbox encryption requires either LOCKBOX_MASTER_KEY or SECRET_KEY_BASE to be set"
end

Rails.logger.debug("Lockbox initialized for attribute encryption")
