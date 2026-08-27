require 'resolv'

# Dependency health, for external monitoring.
#
# Deliberately NOT the container healthcheck: docker-compose probes Rails'
# built-in /up for liveness. Keeping the two apart is the point - if a failing
# dependency marked the container unhealthy, a DNS outage would escalate into a
# restart loop, which makes recovery harder rather than easier.
#
# What this replaced returned a hardcoded {"status":"ok"} and so reported the
# service healthy through five straight days of total DNS failure in August
# 2026, while every handle lookup was failing. A health check that cannot fail
# tells you nothing.
class HealthController < ApplicationController
  # Bounded so a wedged dependency cannot hold a Puma thread open indefinitely.
  CHECK_TIMEOUT = 3 # seconds

  # GET /_health
  # 200 when every dependency answers, 503 otherwise.
  def index
    checks = { database: check_database, dns: check_dns }
    healthy = checks.values.all? { |check| check[:ok] }

    render json: {
      status: healthy ? 'ok' : 'degraded',
      timestamp: Time.current.iso8601,
      service: 'eurosky-migration',
      version: '1.0.0',
      checks: checks
    }, status: healthy ? :ok : :service_unavailable
  end

  private

  def check_database
    timed { ActiveRecord::Base.connection.select_value('SELECT 1') }
  end

  # Outbound name resolution. Nothing this app does - resolving a handle,
  # reading PLC, talking to any PDS - works without it, and it is the dependency
  # that failed in August while the host itself resolved names perfectly well.
  def check_dns
    host = dns_canary_host
    timed(host: host) do
      resolver = Resolv::DNS.new
      # Without this, Resolv's default retry ladder outlives the request.
      resolver.timeouts = [CHECK_TIMEOUT]
      begin
        resolver.getaddress(host)
      ensure
        resolver.close
      end
    end
  end

  def dns_canary_host
    URI.parse(ENV.fetch('ATP_PLC_HOST', 'https://plc.directory')).host
  end

  # Report duration, and on failure the error class only: messages can carry
  # connection strings and internal hostnames, and this endpoint is public.
  def timed(extra = {})
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    extra.merge(ok: true, duration_ms: elapsed_ms(started))
  rescue StandardError => e
    Rails.logger.error("Health check failed: #{e.class}: #{e.message}")
    extra.merge(ok: false, duration_ms: elapsed_ms(started), error: e.class.name)
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  end
end
