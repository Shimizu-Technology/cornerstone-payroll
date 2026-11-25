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

  AUTH_PATH = %r{\A/api/(?:v1/)?(?:auth|sessions|invitations)(?:/|\.[^/]+\z|\z)}
  # The one auth route a client subdomain calls (the employee app's /auth/me).
  TENANT_AUTH_PATH = %r{\A/api/v1/auth/me/?\z}
  EMPLOYEE_PATH = %r{\A/api/v1/employee(?:/|\.[^/]+\z|\z)}
  CLERK_SESSION_PATTERN = /\Asess_[A-Za-z0-9]{1,64}\z/
  BEARER_TOKEN = /\ABearer ([A-Za-z0-9_-]{1,2048}\.[A-Za-z0-9_-]{1,4096}\.[A-Za-z0-9_-]{1,2048})\z/

  def self.request_origin(request)
    request.get_header("HTTP_ORIGIN") || request.get_header("HTTP_X_ORIGIN")
  end

  # The Clerk session of a bearer token that verifies (signature, issuer,
  # expiry, authorized party), as a throttle key, so one restaurant's shared
  # Wi-Fi isn't one bucket. An unverified or forged token has no session
  # here and counts against the per-IP limits instead, so it can neither
  # mint fresh buckets nor spend someone else's. The per-IP backstop below
  # runs first, so a flood stops before any verification work.
  def self.throttle_session(request)
    request.env.fetch("payroll.throttle_session") do
      token = request.get_header("HTTP_AUTHORIZATION").to_s[BEARER_TOKEN, 1]
      payload = begin
        ClerkTokenVerifier.new.verify(token) if token
      rescue StandardError
        nil
      end
      sid = payload["sid"] if payload.is_a?(Hash)
      key = "session:#{Digest::SHA256.hexdigest(sid)}" if sid.is_a?(String) && CLERK_SESSION_PATTERN.match?(sid)
      request.env["payroll.throttle_session"] = key
    end
  end

  # /auth/me from a client subdomain that is registered and switched on. Any
  # other Origin, or any other auth route, keeps the ordinary auth limit.
  def self.tenant_auth?(request)
    TENANT_AUTH_PATH.match?(throttle_path(request)) && TenantSubdomainRegistry.allowed_origin?(request_origin(request))
  end

  # Employee app traffic, and the tenant site's /auth/me: counted per
  # signed-in session where there is one, under a much higher per-IP ceiling.
  def self.employee_session_traffic?(request)
    EMPLOYEE_PATH.match?(throttle_path(request)) || tenant_auth?(request)
  end

  # The tenant site's CORS preflights carry no session and are sent before
  # every call (max_age 0), so they count only against the per-IP backstop.
  def self.session_keyed?(request)
    employee_session_traffic?(request) && !request.options?
  end

  def self.session_or_ip(request)
    throttle_session(request) || throttle_ip(request)
  end

  throttle("api/ip", limit: ENV.fetch("API_THROTTLE_LIMIT", 300).to_i, period: 1.minute) do |request|
    path = throttle_path(request)
    throttle_ip(request) if (path == "/api" || path.start_with?("/api/")) && !employee_session_traffic?(request)
  end

  # The early, unauthenticated backstop for every session-keyed employee and
  # tenant /auth/me request and its preflight: a full shift browsing at once
  # stays well under it. It comes before any limit that verifies a token.
  throttle("employee_session_traffic/ip", limit: 3000, period: 1.minute) do |request|
    throttle_ip(request) if employee_session_traffic?(request) && !employee_activation?(request)
  end

  throttle("auth/ip", limit: ENV.fetch("AUTH_THROTTLE_LIMIT", 20).to_i, period: 1.minute) do |request|
    next unless AUTH_PATH.match?(throttle_path(request))
    next if tenant_auth?(request) && (request.options? || throttle_session(request))

    throttle_ip(request)
  end

  throttle("auth/session", limit: ENV.fetch("AUTH_THROTTLE_LIMIT", 20).to_i, period: 1.minute) do |request|
    throttle_session(request) if tenant_auth?(request) && !request.options?
  end

  throttle("tenant_branding/ip", limit: 120, period: 1.minute) do |request|
    throttle_ip(request) if TenantSubdomainRegistry::BRANDING_PATH.match?(throttle_path(request))
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

  EMPLOYEE_ACTIVATION_PATH = %r{\A/api/v1/employee/(?:activate|activation|invites|invitations|links/(?:claim|reactivate))(?:[/.]|\z)}
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

  # Sign-up and claim have their own limits below.
  throttle("employee/session", limit: 120, period: 1.minute) do |request|
    if session_keyed?(request) && EMPLOYEE_PATH.match?(throttle_path(request)) && !employee_activation?(request)
      session_or_ip(request)
    end
  end

  # A shift signing up together on one Wi-Fi stays under this; each invite's
  # own token or code, and each signed-in session, keep the strict limits.
  throttle("employee/activation_ip", limit: 150, period: 15.minutes) do |request|
    throttle_ip(request) if employee_activation?(request)
  end

  throttle("employee/activation_token", limit: 5, period: 15.minutes) do |request|
    request.env["payroll.activation_token_digest"]
  end

  throttle("employee/activation_session", limit: 10, period: 15.minutes) do |request|
    throttle_session(request) if employee_activation?(request)
  end

  def self.employee_pdf?(request)
    path = throttle_path(request)
    EMPLOYEE_PDF_PATH.match?(path) || EMPLOYEE_DOCUMENT_DOWNLOAD_PATH.match?(path)
  end

  throttle("employee/pdf", limit: 15, period: 1.minute) do |request|
    session_or_ip(request) if employee_pdf?(request) && !request.options?
  end

  throttle("employee/pdf_ip", limit: 300, period: 1.minute) do |request|
    throttle_ip(request) if employee_pdf?(request)
  end

  throttle("kiosk/ip", limit: 60, period: 1.minute) do |request|
    throttle_ip(request) if KIOSK_PATH.match?(throttle_path(request))
  end

  # Throttled and rejected responses never reach Rack::Cors, so they carry the
  # same CORS answer it would give: static origins, and a registered client
  # subdomain on the paths it may call (credentials only on portal paths).
  def self.json_response_headers(request)
    headers = { "content-type" => "application/json", "cache-control" => "no-store", "vary" => "Origin" }
    origin = request_origin(request)
    if PayrollCors.static_origin?(origin)
      headers["access-control-allow-origin"] = origin
      headers["access-control-allow-credentials"] = "true"
      headers["access-control-expose-headers"] = PayrollCors::EXPOSED_HEADERS.join(", ")
    elsif TenantSubdomainRegistry.client_origin?(origin) && PayrollCors.tenant_origin_allowed?(origin, request.env)
      headers["access-control-allow-origin"] = origin
      if TenantSubdomainRegistry::PORTAL_PATH.match?(throttle_path(request))
        headers["access-control-allow-credentials"] = "true"
        headers["access-control-expose-headers"] = PayrollCors::EXPOSED_HEADERS.join(", ")
      end
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
