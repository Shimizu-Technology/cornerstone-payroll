# frozen_string_literal: true

class WriteMaintenance
  SAFE_METHODS = %w[GET HEAD OPTIONS].freeze
  DEFAULT_MESSAGE = "Payroll is in a short maintenance window. Changes are paused. You can still view payroll data. Try again in a few minutes."

  def initialize(app)
    @app = app
  end

  def call(env)
    method = env["REQUEST_METHOD"]
    return @app.call(env) if ENV["WRITE_MAINTENANCE"] != "true" || SAFE_METHODS.include?(method)

    # Match the same path the Rails router will see, including duplicate slashes.
    path = ActionDispatch::Journey::Router::Utils.normalize_path(env["PATH_INFO"])
    return @app.call(env) unless path.start_with?("/api/", "#{ActiveStorage.routes_prefix}/")

    # Paths can contain signed upload tokens. Leave paths and params out of the log.
    Rails.logger.info("[WriteMaintenance] Blocked #{method} request")
    message = ENV["WRITE_MAINTENANCE_MESSAGE"].presence || DEFAULT_MESSAGE
    [ 503, { "content-type" => "application/json", "retry-after" => "60", "cache-control" => "no-store" },
      [ JSON.generate(error: message, code: "write_maintenance") ] ]
  end
end
