# Be sure to restart your server when you modify this file.
#
# Sidekiq configuration for background job processing
#
# Configures both the client (job enqueueing) and server (job processing)

require 'sidekiq'
require 'sidekiq/api'
require 'sidekiq-scheduler'

# Determine Redis URL
redis_url = ENV['REDIS_URL'] || begin
  host = ENV['REDIS_HOST'] || 'localhost'
  port = ENV['REDIS_PORT'] || 6379
  password = ENV['REDIS_PASSWORD']
  db = ENV['REDIS_DB'] || 0

  if password.present?
    "redis://:#{password}@#{host}:#{port}/#{db}"
  else
    "redis://#{host}:#{port}/#{db}"
  end
end

# Sidekiq client configuration
sidekiq_config = {
  url: redis_url
}

# Configure Sidekiq client
Sidekiq.configure_client do |config|
  config.redis = sidekiq_config
end

# Configure Sidekiq server
Sidekiq.configure_server do |config|
  config.redis = sidekiq_config

  # Set concurrency based on environment
  config.concurrency = ENV['SIDEKIQ_CONCURRENCY']&.to_i || (Rails.env.test? ? 1 : 25)

  # Configure queues with priority
  # Queue priorities (weight determines relative processing priority):
  # - critical: 10 (UpdatePlcJob, ActivateAccountJob)
  # - migrations: 5 (ImportPreferencesJob, WaitForPlcTokenJob, and other migration steps)
  # - default: 3 (general application jobs)
  # - low: 1 (cleanup, maintenance, etc.)
  config.queues = [
    ['critical', 10],
    ['migrations', 5],
    ['default', 3],
    ['low', 1]
  ]

  # Add middleware to handle deserialization errors gracefully
  config.server_middleware do |chain|
    chain.add(Class.new do
      def call(worker, job, queue)
        yield
      rescue ActiveJob::DeserializationError => e
        # If we can't deserialize the job arguments (e.g., a Migration was deleted),
        # log it and discard the job rather than retrying indefinitely
        Rails.logger.warn("[Sidekiq] Discarding job #{job['class']} due to deserialization error: #{e.message}")
        # Don't re-raise - this marks the job as successfully completed (but discarded)
      end
    end)
  end

  # Dead letter queue configuration
  config.death_handlers << ->(job, ex) do
    Rails.logger.error("Job failed: #{job['class']} - #{ex.message}")
  end
end

# Configure Active Job to use Sidekiq
Rails.application.config.active_job.queue_adapter = :sidekiq
