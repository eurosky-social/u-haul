# frozen_string_literal: true

# EuroskyConfig - Configuration for deployment modes and UI customization
#
# This module provides centralized configuration for the Eurosky Migration tool.
# All configuration is loaded from environment variables with sensible defaults.
#
# Deployment Modes:
#   - standalone: Users enter their target PDS URL (default)
#   - bound: Target PDS is pre-configured, users cannot change it
#
# UI Customization:
#   - Site name, subtitle, colors, logos are all configurable
#   - Falls back to default Eurosky branding
#
# Invite Codes:
#   - Can be required, optional, or hidden via ENV configuration

module EuroskyConfig
  # Deployment mode configuration
  DEPLOYMENT_MODE = ENV.fetch('DEPLOYMENT_MODE', 'standalone').downcase.freeze
  TARGET_PDS_HOST = ENV['TARGET_PDS_HOST']&.freeze

  # Invite code configuration
  INVITE_CODE_MODE = ENV.fetch('INVITE_CODE_MODE', 'optional').downcase.freeze

  # UI Branding
  SITE_NAME = ENV.fetch('SITE_NAME', 'Eurosky Migration').freeze
  SITE_SUBTITLE = ENV.fetch('SITE_SUBTITLE', 'Migrate your AT Protocol account to a new PDS').freeze
  PRIMARY_COLOR = ENV.fetch('PRIMARY_COLOR', '#667eea').freeze
  SECONDARY_COLOR = ENV.fetch('SECONDARY_COLOR', '#764ba2').freeze
  LOGO_URL = ENV['LOGO_URL']&.freeze
  FAVICON_URL = ENV['FAVICON_URL']&.freeze
  BACKGROUND_IMAGE_URL = ENV['BACKGROUND_IMAGE_URL']&.freeze

  # PDS Configuration
  DEFAULT_TARGET_PDS = ENV['DEFAULT_TARGET_PDS']&.freeze

  # Validation
  class ConfigurationError < StandardError; end

  # Valid deployment modes
  VALID_DEPLOYMENT_MODES = %w[standalone bound].freeze

  # Valid invite code modes
  VALID_INVITE_CODE_MODES = %w[required optional hidden].freeze

  # Validate configuration on load
  def self.validate!
    # Validate deployment mode
    unless VALID_DEPLOYMENT_MODES.include?(DEPLOYMENT_MODE)
      raise ConfigurationError,
            "Invalid DEPLOYMENT_MODE: #{DEPLOYMENT_MODE}. Must be one of: #{VALID_DEPLOYMENT_MODES.join(', ')}"
    end

    # Validate bound mode requires TARGET_PDS_HOST
    if DEPLOYMENT_MODE == 'bound' && TARGET_PDS_HOST.blank?
      raise ConfigurationError,
            "DEPLOYMENT_MODE=bound requires TARGET_PDS_HOST to be set"
    end

    # Validate invite code mode
    unless VALID_INVITE_CODE_MODES.include?(INVITE_CODE_MODE)
      raise ConfigurationError,
            "Invalid INVITE_CODE_MODE: #{INVITE_CODE_MODE}. Must be one of: #{VALID_INVITE_CODE_MODES.join(', ')}"
    end

    # Validate color hex codes
    validate_color!(PRIMARY_COLOR, 'PRIMARY_COLOR')
    validate_color!(SECONDARY_COLOR, 'SECONDARY_COLOR')

    Rails.logger.info("EuroskyConfig loaded: mode=#{DEPLOYMENT_MODE}, invite_codes=#{INVITE_CODE_MODE}")
  end

  # Helper methods
  def self.standalone_mode?
    DEPLOYMENT_MODE == 'standalone'
  end

  def self.bound_mode?
    DEPLOYMENT_MODE == 'bound'
  end

  def self.invite_code_required?
    INVITE_CODE_MODE == 'required'
  end

  def self.invite_code_optional?
    INVITE_CODE_MODE == 'optional'
  end

  def self.invite_code_hidden?
    INVITE_CODE_MODE == 'hidden'
  end

  def self.invite_code_enabled?
    !invite_code_hidden?
  end

  # Get CSS gradient string for backgrounds
  def self.gradient_css
    "linear-gradient(135deg, #{PRIMARY_COLOR} 0%, #{SECONDARY_COLOR} 100%)"
  end

  private

  # Validate color format (supports #hex, rgb(), rgba(), hsl(), hsla(), and named colors)
  def self.validate_color!(color, name)
    return if color.blank?

    # Allow hex colors (#fff, #ffffff)
    return if color.match?(/\A#([0-9a-f]{3}|[0-9a-f]{6})\z/i)

    # Allow rgb/rgba
    return if color.match?(/\Argba?\([^)]+\)\z/i)

    # Allow hsl/hsla
    return if color.match?(/\Ahsla?\([^)]+\)\z/i)

    # Allow CSS named colors (basic set)
    named_colors = %w[
      black white red green blue yellow cyan magenta
      gray grey silver maroon navy purple teal olive
      lime aqua fuchsia transparent
    ]
    return if named_colors.include?(color.downcase)

    raise ConfigurationError,
          "Invalid color format for #{name}: #{color}. Use #hex, rgb(), rgba(), hsl(), hsla(), or named color."
  end
end

# Validate configuration on initialization
EuroskyConfig.validate!
