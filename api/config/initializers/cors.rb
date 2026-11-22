# frozen_string_literal: true

module PayrollCors
  DEFAULT_ORIGINS = %w[
    http://localhost:5173 http://127.0.0.1:5173
    http://localhost:4173 http://127.0.0.1:4173
    http://localhost:4174 http://127.0.0.1:4174
  ].freeze
  STATIC_ORIGINS = ENV.fetch("CORS_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
    .presence&.reject { |origin| origin.include?("*") }&.freeze || DEFAULT_ORIGINS
  METHODS = [ :get, :post, :put, :patch, :delete, :options, :head ].freeze
  EXPOSED_HEADERS = %w[Content-Disposition Retry-After X-Pay-Stubs-Generated X-Pay-Stubs-Skipped].freeze

  def self.static_origin?(origin)
    STATIC_ORIGINS.include?(origin) && !TenantSubdomainRegistry.client_origin?(origin)
  end

  def self.tenant_origin_allowed?(origin, env)
    return false unless TenantSubdomainRegistry::ORIGIN_PATTERN.match?(origin)

    path = TenantSubdomainRegistry.cors_path(env.fetch("PATH_INFO"))
    if TenantSubdomainRegistry::BRANDING_PATH.match?(path)
      method = env["HTTP_ACCESS_CONTROL_REQUEST_METHOD"] if env["REQUEST_METHOD"] == "OPTIONS"
      return false unless TenantSubdomainRegistry::BRANDING_METHODS.include?(method || env["REQUEST_METHOD"])
    elsif !TenantSubdomainRegistry::PORTAL_PATH.match?(path)
      return false
    end

    # Rack::Cors runs before the Rails executor, including for preflights.
    Rails.application.executor.wrap { TenantSubdomainRegistry.allowed_origin?(origin) }
  end
end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins { |origin, _env| PayrollCors.static_origin?(origin) }

    resource "*", headers: :any, methods: PayrollCors::METHODS,
      expose: PayrollCors::EXPOSED_HEADERS, credentials: true
  end

  allow do
    origins { |origin, env| PayrollCors.tenant_origin_allowed?(origin, env) }

    resource TenantSubdomainRegistry::BRANDING_PATH,
      headers: :any, methods: TenantSubdomainRegistry::BRANDING_METHODS.map(&:downcase), credentials: false, max_age: 0
    resource TenantSubdomainRegistry::PORTAL_PATH, headers: :any, methods: PayrollCors::METHODS,
      expose: PayrollCors::EXPOSED_HEADERS, credentials: true, max_age: 0
  end
end
