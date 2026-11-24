# frozen_string_literal: true

class Rack::Attack
  Rack::Attack.cache.store = RackAttackStore.build(ENV["RACK_ATTACK_REDIS_URL"])
  Rack::Attack.enabled = !Rails.env.test?

  def self.throttle_ip(request)
    remote_addr = request.get_header("REMOTE_ADDR").to_s
    trusted_proxies = Rails.application.config.action_dispatch.trusted_proxies.presence ||
                      ActionDispatch::RemoteIp::TRUSTED_PROXIES

    return remote_addr unless trusted_proxies.any? { |proxy| proxy === remote_addr }

    request.ip
  end

  def self.throttle_path(request)
    request.env.fetch("payroll.throttle_path") do
      request.env["payroll.throttle_path"] = TenantSubdomainRegistry.cors_path(request.path).to_s
    end
  end

  throttle("api/ip", limit: ENV.fetch("API_THROTTLE_LIMIT", 300).to_i, period: 1.minute) do |request|
    path = throttle_path(request)
    throttle_ip(request) if path == "/api" || path.start_with?("/api/")
  end

  throttle("auth/ip", limit: ENV.fetch("AUTH_THROTTLE_LIMIT", 20).to_i, period: 1.minute) do |request|
    throttle_ip(request) if throttle_path(request).match?(%r{\A/api/(?:v1/)?(?:auth|sessions|invitations)(?:/|\.[^/]+\z|\z)})
  end

  throttle("tenant_branding/ip", limit: 30, period: 1.minute) do |request|
    path = throttle_path(request)
    origin = request.get_header("HTTP_ORIGIN") || request.get_header("HTTP_X_ORIGIN")
    if TenantSubdomainRegistry::BRANDING_PATH.match?(path) ||
        (TenantSubdomainRegistry::PORTAL_PATH.match?(path) && TenantSubdomainRegistry.client_origin?(origin))
      throttle_ip(request)
    end
  end

  # Logo URLs are content-addressed and cached by browsers, so a shift on one
  # shared Wi-Fi asks for each logo about once.
  throttle("tenant_logo/ip", limit: 60, period: 1.minute) do |request|
    throttle_ip(request) if TenantSubdomainRegistry::LOGO_PATH.match?(throttle_path(request))
  end

  # AIRE proxies every worker from its own servers, so the per-IP API limit is
  # shared. Also bound each worker's statement reads; PDFs are costlier.
  WORKER_STATEMENTS_PATH = %r{\A/api/v1/integrations/time_payroll/workers/([^/]+)/statements(?:/\d+(/pdf)?)?/?\z}

  throttle("worker_statements/worker", limit: ENV.fetch("WORKER_STATEMENT_THROTTLE_LIMIT", 60).to_i, period: 1.minute) do |request|
    match = WORKER_STATEMENTS_PATH.match(throttle_path(request))
    "#{throttle_ip(request)}:#{match[1].downcase}" if match
  end

  throttle("worker_statements/pdf", limit: ENV.fetch("WORKER_STATEMENT_PDF_THROTTLE_LIMIT", 20).to_i, period: 1.minute) do |request|
    match = WORKER_STATEMENTS_PATH.match(throttle_path(request))
    "#{throttle_ip(request)}:#{match[1].downcase}" if match && match[2]
  end

  EMPLOYEE_PATH = %r{\A/api/v1/employee(?:/|\.[^/]+\z|\z)}
  EMPLOYEE_ACTIVATION_PATH = %r{\A/api/v1/employee/(?:activate|activation|invites|invitations|links/claim)(?:[/.]|\z)}
  EMPLOYEE_PDF_PATH = %r{\A/api/v1/employee/(?:.*/)?(?:pdf(?:[/.]|\z)|[^/]+\.pdf\z)}
  EMPLOYEE_DOCUMENT_DOWNLOAD_PATH = %r{\A/api/v1/employee/(?:pay_stubs|w[-_]?2s?)(?:/[^/]+)*/download(?:\.[^/]+)?\z}
  KIOSK_PATH = %r{\A/api/v1/kiosk(?:/|\.[^/]+\z|\z)}
  ACTIVATION_BODY_LIMIT = 4096

  def self.employee_activation?(request)
    request.post? && EMPLOYEE_ACTIVATION_PATH.match?(throttle_path(request))
  end

  def self.activation_payload_status(request)
    return 415 unless request.media_type == "application/json"
    return 413 if request.content_length.to_i > ACTIVATION_BODY_LIMIT

    input = request.body
    return 400 unless input.respond_to?(:rewind)

    begin
      body = input.read(ACTIVATION_BODY_LIMIT + 1).to_s
      return 413 if body.bytesize > ACTIVATION_BODY_LIMIT

      params = JSON.parse(body)
      return 400 unless params.is_a?(Hash)
      # The check reads the JSON body only; naming its fields in the query
      # string too could make layers disagree, so it is refused outright.
      return 400 if EmployeeLinks::Credentials.conflicting_query?(request.GET)

      # The emailed token or the printed code, chosen by the very rule the
      # check uses, so this limit always counts the credential it verifies.
      credential = EmployeeLinks::Credentials.select(token: params["token"], code: params["code"])
      return 400 unless credential

      request.env["payroll.activation_token_digest"] = credential.throttle_key
      nil
    rescue JSON::ParserError, Rack::QueryParser::ParameterTypeError, Rack::QueryParser::InvalidParameterError
      400
    ensure
      input.rewind
    end
  end

  blocklist("employee/activation_payload") do |request|
    if employee_activation?(request)
      request.env["payroll.activation_payload_status"] = activation_payload_status(request)
    end
  end

  self.blocklisted_responder = lambda do |request|
    status = request.env["payroll.activation_payload_status"]
    next Rack::Attack::Configuration::DEFAULT_BLOCKLISTED_RESPONDER.call(request) unless status

    [ status, json_response_headers(request), [ { error: "Invalid activation request" }.to_json ] ]
  end

  throttle("employee/ip", limit: 120, period: 1.minute) do |request|
    throttle_ip(request) if EMPLOYEE_PATH.match?(throttle_path(request))
  end

  throttle("employee/activation_ip", limit: 10, period: 15.minutes) do |request|
    throttle_ip(request) if employee_activation?(request)
  end

  throttle("employee/activation_token", limit: 5, period: 15.minutes) do |request|
    request.env["payroll.activation_token_digest"]
  end

  throttle("employee/pdf", limit: 15, period: 1.minute) do |request|
    path = throttle_path(request)
    throttle_ip(request) if EMPLOYEE_PDF_PATH.match?(path) || EMPLOYEE_DOCUMENT_DOWNLOAD_PATH.match?(path)
  end

  throttle("kiosk/ip", limit: 60, period: 1.minute) do |request|
    throttle_ip(request) if KIOSK_PATH.match?(throttle_path(request))
  end

  def self.json_response_headers(request)
    headers = { "content-type" => "application/json", "cache-control" => "no-store", "vary" => "Origin" }
    origin = request.get_header("HTTP_ORIGIN") || request.get_header("HTTP_X_ORIGIN")
    if PayrollCors.static_origin?(origin)
      headers["access-control-allow-origin"] = origin
      headers["access-control-allow-credentials"] = "true"
      headers["access-control-expose-headers"] = PayrollCors::EXPOSED_HEADERS.join(", ")
    end

    headers
  end

  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    retry_after = match_data[:period].to_i
    headers = json_response_headers(request).merge("retry-after" => retry_after.to_s)

    [ 429, headers, [ { error: "Too many requests", retry_after_seconds: retry_after }.to_json ] ]
  end
end

# A throttled request must never reach the tenant origin lookup, even for OPTIONS.
Rails.application.config.middleware.move_before Rack::Cors, Rack::Attack
