source "https://rubygems.org"

ruby "3.2.2"

# Rails framework
gem "rails", "~> 7.1.5"

# Database
gem "pg", "~> 1.5"

# Web server
gem "puma", "~> 6.4"

# Background jobs
gem "sidekiq", "~> 7.2"
gem "sidekiq-scheduler", "~> 5.0"

# Redis for caching and Sidekiq
gem "redis", "~> 5.0"

# ZIP file creation for backups
gem "rubyzip", "~> 2.3"

# HTTP client
gem "httparty", "~> 0.21"

# ATProto XRPC client
gem "minisky", "~> 0.4"

# Base58 encoding for key generation
gem "base58", "~> 0.2"

# Encryption for sensitive data
gem "lockbox", "~> 1.3"

# JSON builders
gem "jbuilder", "~> 2.11"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

group :development, :test do
  # Debugging
  gem "debug", platforms: %i[ mri windows ]

  # RSpec for testing
  gem "rspec-rails", "~> 6.1"
end

group :test do
  # HTTP mocking and recording
  gem "webmock", "~> 3.19"
  gem "vcr", "~> 6.2"

  # Mocking and stubbing
  gem "mocha", "~> 2.1"
end

