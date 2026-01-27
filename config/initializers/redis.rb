# Be sure to restart your server when you modify this file.
#
# Redis connection configuration for Sidekiq and caching
#
# Supports both full REDIS_URL and individual connection parameters

REDIS_CONFIG = {
  url: ENV['REDIS_URL'] || begin
    host = ENV['REDIS_HOST'] || 'localhost'
    port = ENV['REDIS_PORT'] || 6379
    password = ENV['REDIS_PASSWORD']
    db = ENV['REDIS_DB'] || 0

    if password.present?
      "redis://:#{password}@#{host}:#{port}/#{db}"
    else
      "redis://#{host}:#{port}/#{db}"
    end
  end,
  namespace: "eurosky_migration",
  timeout: 5,
  reconnect_attempts: 1
}.freeze

# Test connection in non-production environments
unless Rails.env.production?
  begin
    redis = Redis.new(url: REDIS_CONFIG[:url], timeout: 2)
    redis.ping
    Rails.logger.debug("Redis connection successful: #{REDIS_CONFIG[:url]}")
  rescue StandardError => e
    Rails.logger.warn("Redis connection failed (development): #{e.message}")
    Rails.logger.warn("Set REDIS_URL environment variable to configure Redis connection")
  end
end
