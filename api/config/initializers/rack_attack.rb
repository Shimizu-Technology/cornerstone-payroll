# frozen_string_literal: true

class Rack::Attack
  Rack::Attack.cache.store = RequestPathCache.store
  Rack::Attack.enabled = !Rails.env.test?

  def self.throttle_ip(request)
    remote_addr = request.get_header("REMOTE_ADDR").to_s
    trusted_proxies = Rails.application.config.action_dispatch.trusted_proxies.presence ||
                      ActionDispatch::RemoteIp::TRUSTED_PROXIES

    return remote_addr unless trusted_proxies.any? { |proxy| proxy === remote_addr }

    request.ip
  end

  throttle("api/ip", limit: ENV.fetch("API_THROTTLE_LIMIT", 300).to_i, period: 1.minute) do |request|
    throttle_ip(request) if request.path.start_with?("/api/")
  end

  throttle("auth/ip", limit: ENV.fetch("AUTH_THROTTLE_LIMIT", 20).to_i, period: 1.minute) do |request|
    throttle_ip(request) if request.path.match?(%r{\A/api/(?:v1/)?(?:auth|sessions|invitations)})
  end

  throttle("tenant_branding/ip", limit: 30, period: 1.minute) do |request|
    path = TenantSubdomainRegistry.cors_path(request.path)
    origin = request.get_header("HTTP_ORIGIN") || request.get_header("HTTP_X_ORIGIN")
    if TenantSubdomainRegistry::BRANDING_PATH.match?(path) ||
        (TenantSubdomainRegistry::PORTAL_PATH.match?(path) && TenantSubdomainRegistry.client_origin?(origin))
      throttle_ip(request)
    end
  end

  # AIRE proxies every worker from its own servers, so the per-IP API limit is
  # shared. Also bound each worker's statement reads; PDFs are costlier.
  WORKER_STATEMENTS_PATH = %r{\A/api/v1/integrations/time_payroll/workers/([^/]+)/statements(?:/\d+(/pdf)?)?/?\z}

  throttle("worker_statements/worker", limit: ENV.fetch("WORKER_STATEMENT_THROTTLE_LIMIT", 60).to_i, period: 1.minute) do |request|
    match = WORKER_STATEMENTS_PATH.match(request.path)
    "#{throttle_ip(request)}:#{match[1].downcase}" if match
  end

  throttle("worker_statements/pdf", limit: ENV.fetch("WORKER_STATEMENT_PDF_THROTTLE_LIMIT", 20).to_i, period: 1.minute) do |request|
    match = WORKER_STATEMENTS_PATH.match(request.path)
    "#{throttle_ip(request)}:#{match[1].downcase}" if match && match[2]
  end

  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    retry_after = match_data[:period].to_i

    headers = { "content-type" => "application/json", "retry-after" => retry_after.to_s,
                "cache-control" => "no-store", "vary" => "Origin" }
    origin = request.get_header("HTTP_ORIGIN") || request.get_header("HTTP_X_ORIGIN")
    if PayrollCors.static_origin?(origin)
      headers["access-control-allow-origin"] = origin
      headers["access-control-allow-credentials"] = "true"
      headers["access-control-expose-headers"] = PayrollCors::EXPOSED_HEADERS.join(", ")
    end

    [ 429, headers, [ { error: "Too many requests", retry_after_seconds: retry_after }.to_json ] ]
  end
end

# A throttled request must never reach the tenant origin lookup, even for OPTIONS.
Rails.application.config.middleware.move_before Rack::Cors, Rack::Attack
