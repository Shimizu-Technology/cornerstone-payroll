# frozen_string_literal: true

module PayrollTelemetry
  RATE_LIMIT_METRIC = "http.rate_limited.payroll"

  class Requests
    def initialize(app)
      @app = app
    end

    def call(env)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @app.call(env)
      status = response.first
      duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000

      # Skip routine requests, including health probes. Paths may contain tokens.
      if status == 429
        throttle = env["rack.attack.matched"]
        PayrollTelemetry.rate_limited(throttle: throttle, duration_ms: duration_ms.round(2))
      elsif status >= 500 || duration_ms >= 500
        PayrollTelemetry.log(:warn, "http.request", status: status, duration_ms: duration_ms.round(2),
          request_id: env["action_dispatch.request_id"])
      end

      response
    end
  end

  module PoolCheckout
    private

    def acquire_connection(...)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super
    ensure
      wait_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      if wait_ms >= 50
        PayrollTelemetry.log(:warn, "db.pool_checkout", pool: db_config.name, wait_ms: wait_ms.round(2))
      end
    end
  end

  def self.log(level, event, **fields)
    Rails.logger.public_send(level, JSON.generate(event: event, process_role: ProcessRole.current, **fields))
  end

  def self.rate_limited(throttle:, duration_ms:)
    fields = { throttle: throttle, count: 1 }
    ActiveSupport::Notifications.instrument(RATE_LIMIT_METRIC, **fields)
    log(:warn, RATE_LIMIT_METRIC, **fields, status: 429, duration_ms: duration_ms)
  end
end

Rails.application.config.middleware.insert_before 0, PayrollTelemetry::Requests

ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionAdapters::ConnectionPool.prepend(PayrollTelemetry::PoolCheckout)
end

ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |_, started, finished, _, payload|
  duration_ms = (finished - started) * 1000
  if duration_ms > 1000 && !payload[:cached]
    # Never include SQL or binds, which can contain payroll data.
    PayrollTelemetry.log(:warn, "db.slow_query", duration_ms: duration_ms.round(2))
  end
end
