# frozen_string_literal: true

class ClerkTokenVerifier
  def verify(token)
    jwks = fetch_jwks
    return nil unless jwks

    unverified = JWT.decode(token, nil, false)
    kid = unverified[1]["kid"]
    jwk = jwks.find { |key| key["kid"] == kid }
    return nil unless jwk

    key = JWT::JWK.new(jwk).public_key
    options = {
      algorithm: "RS256",
      verify_iss: true,
      iss: clerk_issuer,
      verify_expiration: true
    }

    if clerk_audience.present?
      options[:verify_aud] = true
      options[:aud] = clerk_audience
    else
      options[:verify_aud] = false
    end

    JWT.decode(token, key, true, options).first
  rescue JWT::DecodeError, JWT::ExpiredSignature, JWT::InvalidIssuerError => e
    Rails.logger.warn("Clerk JWT verification failed: #{e.message}")
    nil
  end

  private

  def fetch_jwks
    Rails.cache.fetch("clerk_jwks", expires_in: 1.hour, skip_nil: true) do
      uri = URI("#{clerk_api_base}/.well-known/jwks.json")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5
      response = http.get(uri.path)
      if response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body)["keys"]
      else
        Rails.logger.error("Failed to fetch Clerk JWKS: #{response.code}")
        nil
      end
    end
  rescue Timeout::Error, Errno::ECONNREFUSED => e
    Rails.logger.error("Network error fetching Clerk JWKS: #{e.message}")
    nil
  end

  def clerk_issuer
    ENV.fetch("CLERK_ISSUER") { "https://#{clerk_instance_id}.clerk.accounts.dev" }
  end

  def clerk_api_base
    ENV.fetch("CLERK_API_BASE") { "https://#{clerk_instance_id}.clerk.accounts.dev" }
  end

  def clerk_audience
    ENV["CLERK_AUDIENCE"]
  end

  def clerk_instance_id
    ENV.fetch("CLERK_INSTANCE_ID") do
      pk = ENV["CLERK_PUBLISHABLE_KEY"] || ""
      decoded = Base64.decode64(pk.sub(/^pk_(test|live)_/, ""))
      decoded.split(".clerk.accounts.dev").first
    end
  end
end
