# Be sure to restart your server when you modify this file.

# Avoid CORS issues when API is called from the frontend app.
# Handle Cross-Origin Resource Sharing (CORS) in order to accept cross-origin Ajax requests.

# Read more: https://github.com/cyu/rack-cors

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    default_origins = [
      "http://localhost:5173",
      "http://127.0.0.1:5173",
      "http://localhost:4173",
      "http://127.0.0.1:4173",
      "http://localhost:4174",
      "http://127.0.0.1:4174"
    ]
    env_origins = ENV.fetch("CORS_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
    static_origins = (env_origins.empty? ? default_origins : env_origins).reject { |origin| origin.include?("*") }
    origins do |origin, _env|
      normalized_origin = ClerkTokenVerifier.normalize_origin(origin)
      if TenantSubdomainRegistry.client_origin?(normalized_origin)
        # Rack::Cors runs ahead of the Rails executor, including for preflights.
        Rails.application.executor.wrap { TenantSubdomainRegistry.allowed_origin?(origin) }
      else
        static_origins.include?(origin)
      end
    end

    resource "*",
      headers: :any,
      methods: [ :get, :post, :put, :patch, :delete, :options, :head ],
      expose: [ "Content-Disposition", "Retry-After", "X-Pay-Stubs-Generated", "X-Pay-Stubs-Skipped" ],
      credentials: true
  end
end
