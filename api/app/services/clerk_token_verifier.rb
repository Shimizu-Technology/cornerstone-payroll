# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "uri"

class ClerkTokenVerifier
  JWKS_CACHE_TTL = 1.hour
  JWKS_REFRESH_COOLDOWN = 30.seconds
  LEGACY_JWKS_CACHE_KEY = "clerk_jwks"
  PUBLISHABLE_KEY_PATTERN = /\Apk_(?:test|live)_([A-Za-z0-9+_\-\/=]+)\z/
  HOSTNAME_PATTERN = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/i

  def self.normalize_origin(value)
    trimmed = value.to_s.strip
    return nil if trimmed.empty?

    uri = URI.parse(trimmed)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?
    return nil if uri.userinfo.present? || uri.query.present? || uri.fragment.present?
    return nil unless [ "", "/" ].include?(uri.path)

    scheme = uri.scheme.downcase
    host = uri.host.downcase
    default_port = (scheme == "https" ? 443 : 80)
    port_suffix = uri.port && uri.port != default_port ? ":#{uri.port}" : ""
    "#{scheme}://#{host}#{port_suffix}"
  rescue URI::InvalidURIError
    nil
  end

  def self.valid_production_https_origin?(value)
    normalized = normalize_origin(value)
    return false unless normalized

    uri = URI.parse(normalized)
    uri.is_a?(URI::HTTPS) && uri.port == 443
  end

  def self.jwks_cache_key(issuer)
    "clerk_jwks:#{Digest::SHA256.hexdigest(issuer.to_s)}"
  end

  def self.clear_jwks_cache!(env: ENV, cache: nil, extra_issuers: [])
    new(env: env, cache: cache).clear_jwks_cache!(extra_issuers: extra_issuers)
  end

  def initialize(env: ENV, cache: nil, http_get: nil)
    @env = env
    @cache = cache
    @http_get = http_get
  end

  # exp_leeway (seconds) is for offline evidence checks only, such as the
  # readiness probe's pasted sample token; request authentication never passes it.
  def verify(token, exp_leeway: 0)
    return nil if token.blank?

    issuer = clerk_issuer
    if issuer.blank?
      Rails.logger.warn("Clerk JWT verification failed: Clerk issuer is not configured")
      return nil
    end

    unverified = JWT.decode(token, nil, false)
    kid = unverified.dig(1, "kid")
    return nil if kid.blank?

    fetched_fresh = false
    jwks = fetch_jwks { fetched_fresh = true }
    return nil unless jwks

    jwk = find_jwk(jwks, kid)
    if jwk.nil? && !fetched_fresh && refresh_jwks_allowed?
      mark_jwks_refresh_attempt!
      refreshed_jwks = fetch_jwks(force_refresh: true)
      jwk = find_jwk(refreshed_jwks, kid) if refreshed_jwks
    end
    return nil unless jwk

    key = JWT::JWK.new(jwk).public_key
    options = {
      algorithm: "RS256",
      verify_iss: true,
      iss: issuer,
      verify_expiration: true,
      verify_not_before: true
    }
    options[:exp_leeway] = exp_leeway if exp_leeway.positive?

    if clerk_audience.present?
      options[:verify_aud] = true
      options[:aud] = clerk_audience
    else
      options[:verify_aud] = false
    end

    payload = JWT.decode(token, key, true, options).first
    return nil unless valid_authorized_party?(payload)

    payload
  rescue JWT::DecodeError, JWT::ExpiredSignature, JWT::ImmatureSignature, JWT::InvalidIssuerError, JWT::InvalidAudError => e
    Rails.logger.warn("Clerk JWT verification failed: #{e.message}")
    nil
  end

  def clerk_issuer
    explicit = self.class.normalize_origin(@env["CLERK_ISSUER"])
    return explicit if explicit.present?

    host = publishable_key_frontend_api_host
    return "https://#{host}" if host.present?

    instance_id = @env["CLERK_INSTANCE_ID"].to_s.strip
    return nil if instance_id.empty?

    if instance_id.include?(".")
      self.class.normalize_origin("https://#{instance_id}")
    else
      self.class.normalize_origin("https://#{instance_id}.clerk.accounts.dev")
    end
  end

  def clerk_api_base
    explicit = self.class.normalize_origin(@env["CLERK_API_BASE"])
    return explicit if explicit.present?

    clerk_issuer
  end

  def jwks_cache_key
    self.class.jwks_cache_key(clerk_issuer)
  end

  def authorized_parties
    raw = @env["CLERK_AUTHORIZED_PARTIES"].to_s
    raw.split(",").filter_map { |origin| self.class.normalize_origin(origin) }.uniq
  end

  def authorized_parties_configured?
    raw = @env["CLERK_AUTHORIZED_PARTIES"]
    !raw.nil? && !raw.empty?
  end

  def clear_jwks_cache!(extra_issuers: [])
    issuers = ([ clerk_issuer ] + Array(extra_issuers)).filter_map { |value| self.class.normalize_origin(value) }.uniq
    keys = [ LEGACY_JWKS_CACHE_KEY ]
    issuers.each do |issuer|
      keys << self.class.jwks_cache_key(issuer)
      keys << jwks_refresh_cooldown_key(issuer)
    end

    keys.each { |key| cache_store.delete(key) }
    if cache_store.respond_to?(:delete_matched)
      begin
        cache_store.delete_matched(/\Aclerk_jwks(?:_refresh_cooldown)?(?::|\z)/)
      rescue NotImplementedError
        # Some cache stores do not support delete_matched; exact deletes above already ran.
      end
    end

    {
      issuer: clerk_issuer,
      cleared_keys: keys.uniq,
      in_process_only: true
    }
  end

  private

  def cache_store
    @cache || RequestPathCache.store
  end

  def fetch_jwks(force_refresh: false, &on_network_fetch)
    return nil if clerk_issuer.blank? || clerk_api_base.blank?

    if force_refresh
      on_network_fetch&.call
      keys = fetch_jwks_from_network
      cache_store.write(jwks_cache_key, keys, expires_in: JWKS_CACHE_TTL) if keys
      return keys
    end

    cache_store.fetch(jwks_cache_key, expires_in: JWKS_CACHE_TTL, skip_nil: true) do
      on_network_fetch&.call
      fetch_jwks_from_network
    end
  end

  def fetch_jwks_from_network
    uri = URI("#{clerk_api_base}/.well-known/jwks.json")
    if @http_get
      status, body = @http_get.call(uri)
      if status == 200
        parsed = body.is_a?(String) ? JSON.parse(body) : body
        parsed["keys"]
      else
        Rails.logger.error("Failed to fetch Clerk JWKS: #{status}")
        nil
      end
    else
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5
      response = http.get(uri.request_uri)
      if response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body)["keys"]
      else
        Rails.logger.error("Failed to fetch Clerk JWKS: #{response.code}")
        nil
      end
    end
  rescue Timeout::Error, Errno::ECONNREFUSED, SocketError, OpenSSL::SSL::SSLError, JSON::ParserError, URI::InvalidURIError => e
    Rails.logger.error("Network error fetching Clerk JWKS: #{e.message}")
    nil
  end

  def find_jwk(jwks, kid)
    return nil unless jwks.is_a?(Array)

    jwks.find { |key| key.is_a?(Hash) && key["kid"] == kid }
  end

  def refresh_jwks_allowed?
    return false if clerk_issuer.blank?

    !cache_store.read(jwks_refresh_cooldown_key(clerk_issuer))
  end

  def mark_jwks_refresh_attempt!
    return if clerk_issuer.blank?

    cache_store.write(jwks_refresh_cooldown_key(clerk_issuer), true, expires_in: JWKS_REFRESH_COOLDOWN)
  end

  def jwks_refresh_cooldown_key(issuer = clerk_issuer)
    "clerk_jwks_refresh_cooldown:#{Digest::SHA256.hexdigest(issuer.to_s)}"
  end

  def valid_authorized_party?(payload)
    azp = payload["azp"]
    normalized_azp = self.class.normalize_origin(azp) if azp.is_a?(String)
    client_origin = TenantSubdomainRegistry.client_origin?(azp)
    unless authorized_parties_configured?
      if client_origin
        Rails.logger.warn("Clerk JWT verification failed: client subdomain requires CLERK_AUTHORIZED_PARTIES")
      end
      return !client_origin
    end

    parties = authorized_parties
    if parties.empty?
      Rails.logger.warn("Clerk JWT verification failed: CLERK_AUTHORIZED_PARTIES is configured without valid origins")
      return false
    end

    if !azp.is_a?(String) || azp.strip.empty?
      Rails.logger.warn("Clerk JWT verification failed: missing azp claim")
      return false
    end

    allowed = if client_origin
      TenantSubdomainRegistry.allowed_origin?(azp)
    else
      parties.include?(normalized_azp)
    end
    unless allowed
      Rails.logger.warn("Clerk JWT verification failed: unauthorized azp claim")
      return false
    end

    true
  end

  def clerk_audience
    @env["CLERK_AUDIENCE"].presence
  end

  def publishable_key_frontend_api_host
    pk = @env["CLERK_PUBLISHABLE_KEY"].to_s.strip
    match = pk.match(PUBLISHABLE_KEY_PATTERN)
    return nil unless match

    encoded = match[1].tr("-_", "+/")
    padded = encoded + ("=" * ((4 - encoded.length % 4) % 4))
    decoded = Base64.strict_decode64(padded)
    return nil unless decoded.ascii_only?

    host = decoded.sub(/\$\z/, "").strip
    return nil unless host.match?(HOSTNAME_PATTERN)

    host.downcase
  rescue ArgumentError
    nil
  end
end
