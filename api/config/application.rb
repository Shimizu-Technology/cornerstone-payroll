require_relative "boot"
require_relative "../lib/canonical_proxy_headers"
require_relative "../lib/write_maintenance"
require_relative "../lib/logo_upload_body_limit"

# Load environment variables from .env
require "dotenv"
Dotenv.load
require "ipaddr"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require_relative "../lib/process_role"
require "action_mailbox/engine" if ProcessRole.current == ProcessRole::ALL
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Api
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # ActionDispatch::Static bypasses ActionController default response headers,
    # so static files under public/ (such as robots.txt) need explicit security
    # headers configured on public_file_server.
    PUBLIC_FILE_SECURITY_HEADERS = {
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY",
      "x-permitted-cross-domain-policies" => "none",
      "referrer-policy" => "no-referrer"
    }.freeze
    config.public_file_server.headers = PUBLIC_FILE_SECURITY_HEADERS.dup

    # Framework routes are part of the legacy `all` surface.
    config.active_storage.draw_routes = false if ProcessRole.current != ProcessRole::ALL
    config.action_cable.mount_path = nil if ProcessRole.current == ProcessRole::EMPLOYEE_WEB

    # Run after initializer middleware registrations (including CORS) so this
    # remains outermost, before Rails logging and either client-IP resolver.
    initializer "canonical_proxy_headers", after: :load_config_initializers, before: :build_middleware_stack do |app|
      app.middleware.insert_before 0, CanonicalProxyHeaders
    end

    # Preserve CORS and the request ID. Gate before the logger can print signed paths.
    config.middleware.insert_after ActionDispatch::RequestId, WriteMaintenance
    # After CORS, so a refused logo upload is still readable by the browser.
    config.middleware.insert_after WriteMaintenance, LogoUploadBodyLimit

    trusted_proxy_cidrs = ENV.fetch("TRUSTED_PROXY_CIDRS", "")
                               .split(",")
                               .map(&:strip)
                               .reject(&:empty?)
    config.action_dispatch.trusted_proxies = trusted_proxy_cidrs.map { |cidr| IPAddr.new(cidr) } if trusted_proxy_cidrs.any?

    cable_origins = ENV.fetch("CORS_ORIGINS", "")
                       .split(",")
                       .map(&:strip)
                       .reject(&:empty?)
    config.action_cable.allowed_request_origins = cable_origins if cable_origins.any?
  end
end
