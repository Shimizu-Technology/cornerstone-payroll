# frozen_string_literal: true

class WriteMaintenance
  SAFE_METHODS = %w[GET HEAD OPTIONS].freeze
  DEFAULT_MESSAGE = "Payroll is in a short maintenance window. Changes are paused. You can still view payroll data. Try again in a few minutes."

  ENABLED_VALUES = %w[true 1 yes on].freeze
  RETRY_AFTER = 60
  RESPONSE_HEADERS = { "content-type" => "application/json", "retry-after" => RETRY_AFTER.to_s, "cache-control" => "no-store" }.freeze

  def self.enabled?
    value = ENV["WRITE_MAINTENANCE"]
    !value.nil? && ENABLED_VALUES.include?(value.strip.downcase)
  end

  def self.payload(message = nil)
    { error: message || ENV["WRITE_MAINTENANCE_MESSAGE"].presence || DEFAULT_MESSAGE, code: "write_maintenance" }
  end

  def initialize(app)
    @app = app
    Rails.logger.info("[WriteMaintenance] enabled=#{self.class.enabled?}")
  end

  def call(env)
    method = env["REQUEST_METHOD"]
    return @app.call(env) if !self.class.enabled? || SAFE_METHODS.include?(method)

    # Match the same path the Rails router will see, including duplicate slashes.
    path = ActionDispatch::Journey::Router::Utils.normalize_path(env["PATH_INFO"])
    return @app.call(env) unless path.start_with?("/api/", "#{ActiveStorage.routes_prefix}/", "/rails/action_mailbox/", "/rails/conductor/action_mailbox/")

    # Paths can contain signed upload tokens. Leave paths and params out of the log.
    Rails.logger.info("[#{env.fetch("action_dispatch.request_id")}] [WriteMaintenance] Blocked #{method} request (503)")
    [ 503, RESPONSE_HEADERS.dup, [ JSON.generate(self.class.payload) ] ]
  end
end
