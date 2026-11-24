# frozen_string_literal: true

require "securerandom"
require "uri"

module RackAttackStore
  MEMORY = ActiveSupport::Cache::MemoryStore.new(size: 16.megabytes, namespace: "payroll-throttles")

  def self.shared_url?(value)
    url = value.to_s.strip
    uri = URI.parse(url)
    return false unless %w[redis rediss].include?(uri.scheme) && uri.host.present?
    return false if uri.port && !(1..65_535).cover?(uri.port)

    require "redis"
    RedisClient.config(url: url)
    true
  rescue URI::InvalidURIError, ArgumentError
    false
  end

  def self.build(url)
    return MEMORY if url.blank?

    unless shared_url?(url)
      Rails.logger.warn("[Rack::Attack] RACK_ATTACK_REDIS_URL is invalid. Using process-local counters.")
      return MEMORY
    end

    redis = ActiveSupport::Cache::RedisCacheStore.new(
      url: url.strip, namespace: "payroll-throttles", connect_timeout: 0.1, read_timeout: 0.1,
      write_timeout: 0.1, reconnect_attempts: 0, pool: { timeout: 0.1 }, error_handler: nil
    )
    Failover.new(redis, MEMORY)
  end

  class Failover
    def initialize(shared, local)
      @shared = shared
      @local = local
      @retry_at = 0
      @lock = Mutex.new
    end

    # Direct write, read and delete on the shared store, bypassing the local
    # fallback. Production readiness uses it to prove Redis is reachable.
    def shared_round_trip
      key = "readiness/#{SecureRandom.uuid}"
      value = SecureRandom.hex(8)
      @shared.write(key, value, expires_in: 60) && @shared.read(key) == value
    ensure
      @shared.delete(key) if key
    end

    def increment(key, amount, **options)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if now >= @lock.synchronize { @retry_at }
        count = @shared.increment(key, amount, **options)
        return count unless count.nil?

        @lock.synchronize do
          if now >= @retry_at
            @retry_at = now + 5
            Rails.logger.warn("[Rack::Attack] Shared counters unavailable. Using process-local counters.")
          end
        end
      end

      @local.increment(key, amount, **options)
    end
  end
end
