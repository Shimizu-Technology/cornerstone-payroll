# frozen_string_literal: true

require "digest"
require "json"
require "mail"
require "net/http"
require "uri"

# Deployment containment is independent of Rails.env and company payroll mode.
# Errors contain setting names only; never URLs, recipients, payloads or secrets.
class StagingOutboundPolicy
  class Blocked < StandardError; end
  class ConfigurationError < Blocked; end
  LABEL = "STAGING – DO NOT ISSUE OR FILE"
  KNOWN_PRODUCTION_HOSTS = %w[cornerstone-payroll-api.onrender.com cornerstone-payroll.onrender.com aire-services-api.onrender.com aire-services.onrender.com payroll.shimizu-technology.com aire-services-guam.netlify.app].freeze
  DATABASE_SETTINGS = %w[DATABASE_URL MIGRATION_DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL CACHE_MIGRATION_DATABASE_URL QUEUE_MIGRATION_DATABASE_URL CABLE_MIGRATION_DATABASE_URL MIGRATION_CACHE_DATABASE_URL MIGRATION_QUEUE_DATABASE_URL MIGRATION_CABLE_DATABASE_URL].freeze

  class << self
    def staging?(env = ENV)
      env["DEPLOYMENT_ENV"] == "staging"
    end

    def list(name, env)
      env.fetch(name, "").split(",").map { |value| value.strip.downcase }.reject(&:empty?).uniq
    end

    def require_setting!(name, env)
      value = env[name].to_s
      raise ConfigurationError, "Staging requires #{name}" if value.strip.empty?
      value
    end

    def bindings(env = ENV)
      raw = JSON.parse(require_setting!("STAGING_TESTER_BINDINGS", env))
      valid = raw.is_a?(Hash) && !raw.empty? && raw.all? { |email, id| email.match?(URI::MailTo::EMAIL_REGEXP) && id.is_a?(String) && id.match?(/\Auser_[A-Za-z0-9]+\z/) }
      raise ConfigurationError, "Invalid STAGING_TESTER_BINDINGS" unless valid && raw.values.uniq.size == raw.size
      raw.transform_keys(&:downcase)
    rescue JSON::ParserError
      raise ConfigurationError, "Invalid STAGING_TESTER_BINDINGS"
    end

    def tester?(email:, id:, env: ENV)
      return true unless staging?(env)
      bindings(env)[email.to_s.downcase] == id && !id.to_s.empty?
    end

    def clerk_target!(email: nil, id: nil, env: ENV)
      return true unless staging?(env)
      testers = bindings(env)
      allowed = email ? testers.key?(email.to_s.downcase) : testers.value?(id)
      raise Blocked, "Clerk mutation blocked in staging: target is not a named tester" unless allowed
      true
    end

    def integration!(value, env: ENV)
      return true unless staging?(env)
      uri = URI.parse(value.to_s)
      allowed = list("STAGING_INTEGRATION_HOSTS", env)
      denied = KNOWN_PRODUCTION_HOSTS + list("PRODUCTION_INTEGRATION_HOSTS", env)
      valid = uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil? && allowed.include?(uri.host&.downcase) && !denied.include?(uri.host&.downcase)
      raise Blocked, "Integration destination blocked by STAGING_INTEGRATION_HOSTS" unless valid
      true
    rescue URI::InvalidURIError
      raise Blocked, "Invalid staging integration destination"
    end

    def frontend_origin!(value, env: ENV)
      return true unless staging?(env)
      uri = URI.parse(value.to_s)
      origin = "#{uri.scheme}://#{uri.host}"
      allowed = env.values_at("STAGING_AIRE_FRONTEND_ORIGIN", "STAGING_PAYROLL_FRONTEND_ORIGIN")
      valid = uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && allowed.include?(origin) && !KNOWN_PRODUCTION_HOSTS.include?(uri.host)
      raise Blocked, "Browser redirect blocked by staging frontend origins" unless valid
      true
    rescue URI::InvalidURIError
      raise Blocked, "Invalid staging browser redirect"
    end

    def block!(family, env: ENV)
      raise Blocked, "#{family} is disabled in staging; no external request was made" if staging?(env)
      true
    end

    def validate_database!(env: ENV)
      raise ConfigurationError, "Clone containment requires DEPLOYMENT_ENV=staging" unless staging?(env)
      allowed = list("STAGING_DATABASE_HOSTS", env)
      denied = list("PRODUCTION_DATABASE_HOSTS", env)
      raise ConfigurationError, "Staging requires STAGING_DATABASE_HOSTS and PRODUCTION_DATABASE_HOSTS" if allowed.empty? || denied.empty? || !(allowed & denied).empty?
      require_setting!("DATABASE_URL", env)
      DATABASE_SETTINGS.each do |name|
        next if env[name].to_s.empty?
        uri = URI.parse(env[name])
        host = uri.host.to_s.downcase
        raise ConfigurationError, "Unsafe #{name}: staging database host assertion failed" unless %w[postgres postgresql].include?(uri.scheme) && allowed.include?(host) && !denied.include?(host)
      end
      primary = URI.parse(env.fetch("DATABASE_URL"))
      %w[QUEUE_DATABASE_URL CACHE_DATABASE_URL CABLE_DATABASE_URL].each do |name|
        next if env[name].to_s.empty?
        role = URI.parse(env[name])
        primary_identity = [ primary.host.to_s.sub("-pooler.", "."), primary.port || 5432, primary.path ]
        role_identity = [ role.host.to_s.sub("-pooler.", "."), role.port || 5432, role.path ]
        unless primary_identity == role_identity
          raise ConfigurationError, "Separate #{name} is unsupported by staging clone containment; use the primary clone database"
        end
      end
      true
    rescue URI::InvalidURIError
      raise ConfigurationError, "Invalid staging database URL"
    end

    def validate_storage!(env: ENV, bucket: nil, access_key: nil)
      return true unless staging?(env)
      expected = require_setting!("STAGING_STORAGE_BUCKET", env)
      production = require_setting!("PRODUCTION_STORAGE_BUCKET", env)
      actual = bucket || env["R2_BUCKET_NAME"] || env["R2_BUCKET"] || env["AWS_S3_BUCKET"]
      valid = expected.match?(/(?:\A|[-_])staging(?:[-_]|\z)/) && expected != production && actual == expected
      raise ConfigurationError, "Unsafe STAGING_STORAGE_BUCKET / PRODUCTION_STORAGE_BUCKET" unless valid
      key = access_key || env["R2_ACCESS_KEY_ID"] || env["AWS_ACCESS_KEY_ID"]
      fingerprint = Digest::SHA256.hexdigest(key.to_s)
      approved = require_setting!("STAGING_STORAGE_ACCESS_KEY_SHA256", env)
      denied = require_setting!("PRODUCTION_STORAGE_ACCESS_KEY_SHA256", env)
      valid_key = approved.match?(/\A[0-9a-f]{64}\z/) && denied.match?(/\A[0-9a-f]{64}\z/) && approved != denied && fingerprint == approved && fingerprint != denied
      raise ConfigurationError, "Unsafe STAGING_STORAGE_ACCESS_KEY_SHA256 / PRODUCTION_STORAGE_ACCESS_KEY_SHA256" unless valid_key
      require_setting!(env.key?("R2_ACCESS_KEY_ID") ? "R2_SECRET_ACCESS_KEY" : "AWS_SECRET_ACCESS_KEY", env)
      true
    end

    def validate!(env: ENV)
      return true unless staging?(env)
      validate_database!(env: env)
      validate_storage!(env: env)
      issuer = require_setting!("CLERK_ISSUER", env)
      expected = require_setting!("STAGING_CLERK_ISSUER", env)
      production = require_setting!("PRODUCTION_CLERK_ISSUER", env)
      uri = URI.parse(issuer)
      valid = issuer == expected && issuer != production && uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && [ "", "/" ].include?(uri.path) && uri.query.nil? && uri.fragment.nil?
      raise ConfigurationError, "Unsafe CLERK_ISSUER / STAGING_CLERK_ISSUER" unless valid
      jwks = env["CLERK_JWKS_URL"]
      raise ConfigurationError, "Unsafe CLERK_JWKS_URL" if jwks && jwks != "#{issuer.delete_suffix('/')}/.well-known/jwks.json"
      raise ConfigurationError, "Staging requires a separate CLERK_SECRET_KEY (sk_test_)" unless env["CLERK_SECRET_KEY"].to_s.start_with?("sk_test_")
      require_setting!("STAGING_INTEGRATION_HOSTS", env)
      require_setting!("PRODUCTION_INTEGRATION_HOSTS", env)
      list("STAGING_INTEGRATION_HOSTS", env).each { |host| integration!("https://#{host}", env: env) }
      integration!(require_setting!("CORNERSTONE_PAYROLL_EVENTS_URL", env), env: env)
      integration!(require_setting!("STAGING_AIRE_BASE_URL", env), env: env)
      %w[STAGING_AIRE_FRONTEND_ORIGIN STAGING_PAYROLL_FRONTEND_ORIGIN].each do |name|
        frontend_origin!(require_setting!(name, env), env: env)
      end
      frontend = require_setting!("STAGING_FRONTEND_ORIGIN", env)
      front_uri = URI.parse(frontend)
      unless front_uri.is_a?(URI::HTTPS) && front_uri.port == 443 && front_uri.userinfo.nil? && [ "", "/" ].include?(front_uri.path) && !KNOWN_PRODUCTION_HOSTS.include?(front_uri.host)
        raise ConfigurationError, "Unsafe STAGING_FRONTEND_ORIGIN"
      end
      raise ConfigurationError, "FRONTEND_URL must match STAGING_FRONTEND_ORIGIN" unless env["FRONTEND_URL"] == frontend
      origins = env.fetch("CORS_ORIGINS", frontend).split(",").map(&:strip)
      raise ConfigurationError, "CORS_ORIGINS must contain only STAGING_FRONTEND_ORIGIN" unless origins == [ frontend ]
      raise ConfigurationError, "Staging requires STAGING_ACCESS_GATE_ASSERTED=true" unless env["STAGING_ACCESS_GATE_ASSERTED"] == "true"
      %w[CST_INGEST_URL CST_API_TOKEN CST_SHARED_SECRET OPENROUTER_API_KEY WORKOS_API_KEY WORKOS_CLIENT_ID].each do |name|
        raise ConfigurationError, "Remove #{name} in staging" unless env[name].to_s.empty?
      end
      raise ConfigurationError, "Staging requires AUTH_ENABLED=true" unless env.fetch("AUTH_ENABLED", "true") == "true"
      raise ConfigurationError, "Remove R2_PUBLIC_URL in staging; use staging bucket presigning" unless env["R2_PUBLIC_URL"].to_s.empty?
      if env["RESEND_API_KEY"].to_s != ""
        approved_mail_key = require_setting!("STAGING_RESEND_API_KEY_SHA256", env)
        production_mail_key = require_setting!("PRODUCTION_RESEND_API_KEY_SHA256", env)
        actual_mail_key = Digest::SHA256.hexdigest(env["RESEND_API_KEY"])
        unless actual_mail_key == approved_mail_key && actual_mail_key != production_mail_key && !list("STAGING_MAIL_ALLOWLIST", env).empty?
          raise ConfigurationError, "Unsafe staging RESEND_API_KEY assertion"
        end
      end
      %w[SECRET_KEY_BASE PAYROLL_SHARED_SECRET].each do |name|
        value = require_setting!(name == "PAYROLL_SHARED_SECRET" ? "STAGING_PAYROLL_SHARED_SECRET" : name, env)
        production_fingerprint = require_setting!("PRODUCTION_#{name}_SHA256", env)
        raise ConfigurationError, "Unsafe staging #{name} assertion" if value.length < 32 || !production_fingerprint.match?(/\A[0-9a-f]{64}\z/) || Digest::SHA256.hexdigest(value) == production_fingerprint
      end
      if env["PAYROLL_SHARED_SECRET"] && env["PAYROLL_SHARED_SECRET"] != env["STAGING_PAYROLL_SHARED_SECRET"]
        raise ConfigurationError, "PAYROLL_SHARED_SECRET must match STAGING_PAYROLL_SHARED_SECRET"
      end
      bindings(env)
      unless (list("STAGING_MAIL_ALLOWLIST", env) - bindings(env).keys).empty?
        raise ConfigurationError, "STAGING_MAIL_ALLOWLIST must contain named testers only"
      end
      true
    rescue URI::InvalidURIError
      raise ConfigurationError, "Invalid staging containment URL"
    end

    def mail_payload(payload, env: ENV)
      return payload unless staging?(env)
      allowed = list("STAGING_MAIL_ALLOWLIST", env) & bindings(env).keys
      filtered = payload.transform_keys(&:to_sym).dup
      %i[to cc bcc reply_to].each do |field|
        addresses = Array(filtered[field]).flat_map { |value| Mail::AddressList.new(value.to_s).addresses.map(&:address) }
        addresses = addresses.map(&:downcase).select { |address| allowed.include?(address) }.uniq
        addresses.empty? ? filtered.delete(field) : filtered[field] = addresses
      end
      return nil if Array(filtered[:to]).empty?
      filtered[:subject] = "[STAGING] #{filtered[:subject]}" unless filtered[:subject].to_s.start_with?("[STAGING]")
      filtered.delete(:attachments)
      filtered.delete(:headers)
      html = filtered.delete(:html)
      filtered[:text] ||= ActionView::Base.full_sanitizer.sanitize(html.to_s) if html
      filtered
    rescue Mail::Field::ParseError
      nil
    end

    # A final guard catches new or indirect transports, redirects and SDK calls.
    # Explicit per-family checks provide useful user-facing errors earlier.
    def http_host!(host, port, ssl, env: ENV)
      return true unless staging?(env)
      allowed = list("STAGING_INTEGRATION_HOSTS", env) + [ "api.clerk.com", URI(env.fetch("CLERK_ISSUER", "https://invalid")).host, "api.resend.com" ] + storage_hosts(env)
      denied = KNOWN_PRODUCTION_HOSTS + list("PRODUCTION_INTEGRATION_HOSTS", env)
      raise Blocked, "Outbound network disabled by staging policy" unless ssl && port == 443 && allowed.include?(host.downcase) && !denied.include?(host.downcase)
      true
    end

    def storage_hosts(env)
      if env["R2_ACCOUNT_ID"]
        [ URI(env["R2_ENDPOINT"] || "https://#{env['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com").host ]
      else
        bucket = env["STAGING_STORAGE_BUCKET"]
        region = env["AWS_REGION"]
        [ "#{bucket}.s3.#{region}.amazonaws.com", "s3.#{region}.amazonaws.com", "#{bucket}.s3.amazonaws.com", "s3.amazonaws.com" ]
      end
    end

    def http_request!(http, request, env: ENV)
      return true unless staging?(env)
      http_host!(http.address, http.port, http.use_ssl?, env: env)
      host = http.address.downcase
      path = URI.parse(request.path).path
      if host == "api.resend.com"
        raise Blocked, "Mail must use StagingMailTransport" unless Thread.current[:staging_mail_transport] && request.method == "POST" && path == "/emails"
      elsif host == "api.clerk.com"
        clerk_request!(request, path, env)
      elsif host == URI(env.fetch("CLERK_ISSUER")).host
        raise Blocked, "Only staging Clerk JWKS reads are allowed" unless request.method == "GET" && path == "/.well-known/jwks.json"
      elsif storage_hosts(env).include?(host)
        validate_storage!(env: env)
        bucket = env.fetch("STAGING_STORAGE_BUCKET")
        unless host.start_with?("#{bucket}.s3.") || path == "/#{bucket}" || path.start_with?("/#{bucket}/")
          raise Blocked, "Storage request is outside STAGING_STORAGE_BUCKET"
        end
      else
        integration!("https://#{host}#{request.path}", env: env)
      end
      true
    end

    def clerk_request!(request, path, env)
      return true if request.method == "GET" && path.match?(%r{\A/v1/(?:users(?:/[^/]+)?|instance)\z})
      if request.method == "POST" && path == "/v1/invitations"
        clerk_target!(email: JSON.parse(request.body.to_s)["email_address"], env: env)
      elsif request.method == "PATCH" && (match = path.match(%r{\A/v1/users/([^/]+)\z}))
        clerk_target!(id: match[1], env: env)
      elsif request.method == "POST" && (match = path.match(%r{\A/v1/invitations/([^/]+)/revoke\z}))
        user = User.find_by(clerk_invitation_id: match[1]) if User.column_names.include?("clerk_invitation_id")
        clerk_target!(email: user&.email, env: env)
      else
        raise Blocked, "Clerk operation blocked in staging"
      end
    rescue JSON::ParserError
      raise Blocked, "Invalid staging Clerk operation"
    end
  end
end
