# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require "uri"

# DEPLOYMENT_ENV=local runs the production build (RAILS_ENV=production) on a
# developer machine: loopback databases and Redis, disk storage, mail written
# to files, a Clerk development instance and tenant hosts under a *.localhost
# root domain. It refuses to boot on a hosted platform, with live keys or with
# remote credentials, so a copied environment cannot turn a real service into
# a local one. Every outbound connection outside loopback and Clerk is refused.
# Errors contain setting names only; never URLs, recipients or secrets.
module LocalDeployment
  class ConfigurationError < StandardError; end

  HOSTED_MARKERS = %w[RENDER RENDER_SERVICE_ID RENDER_EXTERNAL_URL RENDER_GIT_COMMIT NETLIFY CI GITHUB_ACTIONS].freeze
  REMOTE_CREDENTIALS = %w[
    RESEND_API_KEY R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_URL R2_ENDPOINT
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY OPENROUTER_API_KEY CST_INGEST_URL CST_API_TOKEN CST_SHARED_SECRET
    WORKOS_API_KEY WORKOS_CLIENT_ID
  ].freeze
  DATABASE_SETTINGS = %w[
    DATABASE_URL RLS_DATABASE_URL MIGRATION_DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL
    CACHE_MIGRATION_DATABASE_URL QUEUE_MIGRATION_DATABASE_URL CABLE_MIGRATION_DATABASE_URL
    MIGRATION_CACHE_DATABASE_URL MIGRATION_QUEUE_DATABASE_URL MIGRATION_CABLE_DATABASE_URL RACK_ATTACK_REDIS_URL
  ].freeze
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze
  ROOT_DOMAIN_PATTERN = /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+localhost\z/
  CLERK_DEVELOPMENT_ISSUER = %r{\Ahttps://[a-z0-9-]+\.clerk\.accounts\.dev/?\z}
  CLERK_API_HOST = "api.clerk.com"
  LIVE_KEY = /\A(?:sk|pk)_live_/

  module_function

  def local?(env = ENV)
    env["DEPLOYMENT_ENV"] == "local"
  end

  def validate!(env: ENV)
    return true unless local?(env)

    hosted = HOSTED_MARKERS.select { |name| env[name].to_s.strip != "" }
    fail!("DEPLOYMENT_ENV=local is refused on a hosted platform or CI (#{hosted.join(', ')})") if hosted.any?
    live = env.select { |_name, value| value.to_s.strip.match?(LIVE_KEY) }.keys.sort
    fail!("DEPLOYMENT_ENV=local is refused with live keys (#{live.join(', ')})") if live.any?
    remote = REMOTE_CREDENTIALS.select { |name| env[name].to_s.strip != "" }
    fail!("Remove #{remote.join(', ')} for DEPLOYMENT_ENV=local") if remote.any?

    fail!("DEPLOYMENT_ENV=local requires AUTH_ENABLED=true") unless env.fetch("AUTH_ENABLED", "true") == "true"
    fail!("DEPLOYMENT_ENV=local requires CLERK_SECRET_KEY (sk_test_)") unless env["CLERK_SECRET_KEY"].to_s.start_with?("sk_test_")
    if env["CLERK_PUBLISHABLE_KEY"].to_s != "" && !env["CLERK_PUBLISHABLE_KEY"].start_with?("pk_test_")
      fail!("DEPLOYMENT_ENV=local requires CLERK_PUBLISHABLE_KEY (pk_test_)")
    end
    fail!("DEPLOYMENT_ENV=local requires a Clerk development CLERK_ISSUER") unless env["CLERK_ISSUER"].to_s.match?(CLERK_DEVELOPMENT_ISSUER)
    unless env["ACTIVE_STORAGE_SERVICE"] == "local" && env["R2_STORAGE_BACKEND"] == "local"
      fail!("DEPLOYMENT_ENV=local requires ACTIVE_STORAGE_SERVICE=local and R2_STORAGE_BACKEND=local")
    end
    fail!("DEPLOYMENT_ENV=local requires an absolute LOCAL_MAIL_CAPTURE_DIR") unless env["LOCAL_MAIL_CAPTURE_DIR"].to_s.start_with?("/")

    root = tenant_root_domain(env)
    fail!("DEPLOYMENT_ENV=local requires TENANT_ROOT_DOMAIN under .localhost") unless root
    https_port(env)
    DATABASE_SETTINGS.each do |name|
      fail!("#{name} must point at a loopback service for DEPLOYMENT_ENV=local") if env[name].to_s != "" && !loopback_url?(env[name])
    end
    fail!("FRONTEND_URL must be a local HTTPS origin") unless local_origin?(env["FRONTEND_URL"], env)
    %w[CORS_ORIGINS CLERK_AUTHORIZED_PARTIES].each do |name|
      origins = env.fetch(name, "").split(",").map(&:strip).reject(&:empty?)
      fail!("#{name} must list only local HTTPS origins") unless origins.all? { |origin| local_origin?(origin, env) }
    end
    true
  end

  # The tenant root domain on this machine, e.g. "cornerstone.localhost". nil
  # outside local mode, so hosted services always use the production domain.
  def tenant_root_domain(env = ENV)
    return unless local?(env)

    value = env["TENANT_ROOT_DOMAIN"].to_s.downcase
    value if value.match?(ROOT_DOMAIN_PATTERN)
  end

  # Browsers include a non-default port in Origin, so tenant origins carry it.
  def https_port(env = ENV)
    return 443 unless local?(env)

    port = Integer(env.fetch("LOCAL_HTTPS_PORT", "443").to_s, 10)
    fail!("LOCAL_HTTPS_PORT must be 443 or 1024-65535") unless port == 443 || port.between?(1024, 65_535)
    port
  rescue ArgumentError
    fail!("LOCAL_HTTPS_PORT must be 443 or 1024-65535")
  end

  def port_suffix(env = ENV)
    port = https_port(env)
    port == 443 ? "" : ":#{port}"
  end

  # An exact HTTPS origin under the local tenant root domain and port.
  def local_origin?(value, env = ENV)
    root = tenant_root_domain(env)
    return false unless root

    uri = URI.parse(value.to_s)
    host = uri.host.to_s.downcase
    uri.is_a?(URI::HTTPS) && uri.port == https_port(env) && uri.userinfo.nil? && [ "", "/" ].include?(uri.path) &&
      uri.query.nil? && uri.fragment.nil? && (host == root || host.end_with?(".#{root}"))
  rescue URI::InvalidURIError
    false
  end

  def loopback_url?(value)
    uri = URI.parse(value.to_s)
    host = uri.host.to_s.downcase
    return LOOPBACK_HOSTS.include?(host) unless host.empty?

    # A Unix socket: postgres:///db?host=/path
    socket = URI.decode_www_form(uri.query.to_s).to_h["host"]
    socket.nil? || socket.start_with?("/")
  rescue URI::InvalidURIError, ArgumentError
    false
  end

  # Loopback (any port, including *.localhost) and the Clerk development
  # instance over TLS. Nothing else leaves the machine.
  def outbound_allowed?(host, port, ssl, env: ENV)
    host = host.to_s.downcase.delete_suffix(".")
    return true if LOOPBACK_HOSTS.include?(host) || host == "localhost" || host.end_with?(".localhost")

    clerk_hosts = [ CLERK_API_HOST, (URI.parse(env["CLERK_ISSUER"].to_s).host.to_s.downcase if env["CLERK_ISSUER"].to_s.match?(CLERK_DEVELOPMENT_ISSUER)) ].compact
    ssl && port == 443 && clerk_hosts.include?(host)
  rescue URI::InvalidURIError
    false
  end

  # Writes each message as one JSON file instead of sending it. Attachments
  # keep their names and sizes only.
  def capture_mail!(payload, options: {}, env: ENV)
    dir = env.fetch("LOCAL_MAIL_CAPTURE_DIR")
    FileUtils.mkdir_p(dir, mode: 0o700)
    id = "local-#{Time.now.utc.strftime('%Y%m%dT%H%M%S%6N')}-#{SecureRandom.hex(4)}"
    message = payload.to_h.transform_keys(&:to_s)
    message["attachments"] = Array(message["attachments"]).map do |attachment|
      attachment = attachment.to_h.transform_keys(&:to_s)
      { "filename" => attachment["filename"], "bytes" => attachment["content"].to_s.bytesize }
    end
    message["idempotency_key"] = options[:idempotency_key] if options[:idempotency_key]
    message["captured_at"] = Time.now.utc.iso8601(6)
    File.open(File.join(dir, "#{id}.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(message)) }
    { "id" => id, "local_captured" => true }
  end

  def fail!(message)
    raise ConfigurationError, message
  end
end
