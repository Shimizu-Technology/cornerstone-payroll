# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "mail"
require "net/http"
require "uri"
require_relative "staging_database_policy"
require_relative "staging_storage_policy"

# Deployment containment is independent of Rails.env and company payroll mode.
# Errors contain setting names only; never URLs, recipients, payloads or secrets.
class StagingOutboundPolicy
  class Blocked < StandardError; end
  class ConfigurationError < Blocked; end
  LABEL = "STAGING – DO NOT ISSUE OR FILE"
  KNOWN_PRODUCTION_HOSTS = %w[cornerstone-payroll-api.onrender.com cornerstone-payroll.onrender.com aire-services-api.onrender.com aire-services.onrender.com payroll.shimizu-technology.com aire-services-guam.netlify.app app.aireservicesguam.com].freeze
  DATABASE_SETTINGS = %w[DATABASE_URL MIGRATION_DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL CACHE_MIGRATION_DATABASE_URL QUEUE_MIGRATION_DATABASE_URL CABLE_MIGRATION_DATABASE_URL MIGRATION_CACHE_DATABASE_URL MIGRATION_QUEUE_DATABASE_URL MIGRATION_CABLE_DATABASE_URL].freeze

  class << self
    def staging?(env = ENV)
      value = env["DEPLOYMENT_ENV"]
      raise ConfigurationError, "Invalid DEPLOYMENT_ENV" if value && !value.empty? && !%w[staging production test development].include?(value)
      value == "staging"
    end

    # Both exceptions form one explicit staging-only contract. Empty/false values
    # are not opt-outs: remove all three settings to use isolated credentials.
    def shared_production_credentials?(env = ENV)
      return false unless staging?(env)

      names = %w[STAGING_SHARES_PRODUCTION_CLERK STAGING_SHARES_PRODUCTION_STORAGE]
      if env.keys.any? { |key| key.start_with?("STAGING_SHARES_PRODUCTION_") && !names.include?(key) }
        raise ConfigurationError, "Unknown STAGING_SHARES_PRODUCTION setting"
      end
      flags = env.values_at(*names)
      return false if flags.all?(&:nil?) && !env.key?("STAGING_STORAGE_WRITE_PREFIX")
      unless flags == [ "true", "true" ]
        raise ConfigurationError, "STAGING_SHARES_PRODUCTION_CLERK / STAGING_SHARES_PRODUCTION_STORAGE must both be exactly true"
      end
      prefix = env["STAGING_STORAGE_WRITE_PREFIX"].to_s
      valid = prefix.match?(%r{\Astaging/\d{4}-\d{2}-\d{2}/\z}) && !prefix.start_with?("staging/0000-")
      begin
        valid &&= Date.iso8601(prefix.split("/")[1]).iso8601 == prefix.split("/")[1]
      rescue Date::Error
        valid = false
      end
      raise ConfigurationError, "Invalid STAGING_STORAGE_WRITE_PREFIX: require staging/YYYY-MM-DD/" unless valid
      true
    end

    def validate_deployment!(env: ENV, environment: Rails.env)
      staging?(env)
      if (environment.to_s == "production" || env["RAILS_ENV"] == "production") && !%w[staging production].include?(env["DEPLOYMENT_ENV"])
        raise ConfigurationError, "Production boot requires explicit DEPLOYMENT_ENV=production or staging"
      end
      true
    end

    def list(name, env)
      env.fetch(name, "").split(",").map { |value| value.strip.downcase }.reject(&:empty?).uniq
    end

    def require_setting!(name, env)
      value = env[name].to_s
      raise ConfigurationError, "Staging requires #{name}" if value.strip.empty?
      value
    end

    def tester_records(env = ENV)
      records = JSON.parse(require_setting!("STAGING_TESTER_BINDINGS", env))
      valid = records.is_a?(Array) && (1..2).cover?(records.size) && records.all? do |record|
        record.is_a?(Hash) && record["user_id"].is_a?(Integer) && record["user_id"].positive? &&
          record["email"].is_a?(String) && record["email"] == record["email"].strip && record["email"].match?(URI::MailTo::EMAIL_REGEXP) &&
          record["clerk_subject"].is_a?(String) && record["clerk_subject"].match?(/\Auser_[A-Za-z0-9]+\z/)
      end
      raise ConfigurationError, "Invalid STAGING_TESTER_BINDINGS: require explicit user_id/email/clerk_subject triples" unless valid
      records = records.map { |record| record.merge("email" => record["email"].downcase) }
      unless %w[user_id email clerk_subject].all? { |key| records.map { |record| record[key] }.uniq.size == records.size }
        raise ConfigurationError, "STAGING_TESTER_BINDINGS must be unique"
      end
      records
    rescue JSON::ParserError
      raise ConfigurationError, "Invalid STAGING_TESTER_BINDINGS"
    end

    def bindings(env = ENV)
      tester_records(env).to_h { |record| [ record.fetch("email"), record.fetch("clerk_subject") ] }
    end

    def tester?(email:, id:, user_id: nil, env: ENV)
      return true unless staging?(env)
      tester_records(env).any? { |record| record["user_id"] == user_id && record["email"] == email.to_s.downcase && record["clerk_subject"] == id }
    end

    def clerk_target!(email: nil, id: nil, env: ENV)
      return true unless staging?(env)
      raise Blocked, "Clerk mutations are disabled with shared production credentials" if shared_production_credentials?(env)
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
      origin = "#{uri.scheme}://#{uri.host.to_s.downcase}"
      allowed = env.values_at("STAGING_AIRE_FRONTEND_ORIGIN", "STAGING_PAYROLL_FRONTEND_ORIGIN")
      valid = uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && allowed.compact.map(&:downcase).include?(origin) && !(KNOWN_PRODUCTION_HOSTS + list("PRODUCTION_FRONTEND_HOSTS", env) + list("PRODUCTION_INTEGRATION_HOSTS", env)).include?(uri.host.to_s.downcase)
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
      StagingDatabasePolicy.validate_config!(env: env)
    end

    def validate_storage!(env: ENV, bucket: nil, access_key: nil)
      StagingStoragePolicy.validate!(env: env, bucket: bucket, access_key: access_key)
    end

    def validate!(env: ENV)
      validate_deployment!(env: env)
      return true unless staging?(env)
      shared = shared_production_credentials?(env)
      validate_database!(env: env)
      validate_storage!(env: env)
      issuer = require_setting!("CLERK_ISSUER", env)
      expected = require_setting!("STAGING_CLERK_ISSUER", env)
      production = require_setting!("PRODUCTION_CLERK_ISSUER", env)
      uri = URI.parse(issuer)
      valid = issuer == expected && (shared || issuer != production) && uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && [ "", "/" ].include?(uri.path) && uri.query.nil? && uri.fragment.nil?
      raise ConfigurationError, "Unsafe CLERK_ISSUER / STAGING_CLERK_ISSUER" unless valid
      jwks = env["CLERK_JWKS_URL"]
      raise ConfigurationError, "Unsafe CLERK_JWKS_URL" if jwks && jwks != "#{issuer.delete_suffix('/')}/.well-known/jwks.json"
      raise ConfigurationError, "Staging requires CLERK_SECRET_KEY (sk_test_)" unless env["CLERK_SECRET_KEY"].to_s.start_with?("sk_test_")
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
      unless front_uri.is_a?(URI::HTTPS) && front_uri.port == 443 && front_uri.userinfo.nil? && [ "", "/" ].include?(front_uri.path) && !(KNOWN_PRODUCTION_HOSTS + list("PRODUCTION_FRONTEND_HOSTS", env) + list("PRODUCTION_INTEGRATION_HOSTS", env)).include?(front_uri.host.to_s.downcase)
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
      StagingStoragePolicy.hosts(env)
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
        if StagingStoragePolicy.shared?(env: env) && !%w[GET HEAD].include?(request.method)
          key = host.start_with?("#{bucket}.s3.") ? path.delete_prefix("/") : path.delete_prefix("/#{bucket}/")
          StagingStoragePolicy.write!(URI::DEFAULT_PARSER.unescape(key), env: env)
        end
      else
        integration!("https://#{host}#{request.path}", env: env)
      end
      true
    end

    def clerk_request!(request, path, env)
      return true if request.method == "GET" && path.match?(%r{\A/v1/(?:users(?:/[^/]+)?|instance)\z})
      raise Blocked, "Clerk mutations are disabled with shared production credentials" if shared_production_credentials?(env)
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
