# frozen_string_literal: true

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

    def increment(key, amount, **options)
      with_failover(-> { @shared.increment(key, amount, **options) }, -> { @local.increment(key, amount, **options) })
    end

    def read(key, **options)
      with_failover(-> { @shared.read(key, **options) }, -> { @local.read(key, **options) }, treat_nil_as_error: false)
    end

    def write(key, value, **options)
      with_failover(-> { @shared.write(key, value, **options) }, -> { @local.write(key, value, **options) })
    end

    def delete(key, **options)
      with_failover(-> { @shared.delete(key, **options) }, -> { @local.delete(key, **options) }, treat_nil_as_error: false)
    end

    private

    def with_failover(shared_op, local_op, treat_nil_as_error: true)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if now >= @lock.synchronize { @retry_at }
        begin
          result = shared_op.call
          return result if !treat_nil_as_error || !result.nil?
        rescue StandardError
          # Fall through to failover cooldown and local store.
        end

        @lock.synchronize do
          if now >= @retry_at
            @retry_at = now + 5
            Rails.logger.warn("[Rack::Attack] Shared counters unavailable. Using process-local counters.")
          end
        end
      end

      local_op.call
    end
  end
end
