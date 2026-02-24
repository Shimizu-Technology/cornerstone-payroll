# frozen_string_literal: true

# Clerk JWT authentication concern.
# Verifies Bearer tokens using Clerk's JWKS endpoint.
# Following the pattern from Brain Dump / CLERK_AUTH_SETUP_GUIDE.md
module ClerkAuthenticatable
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_user!, unless: :auth_disabled?
  end

  private

  def authenticate_user!
    token = extract_token
    unless token
      render json: { error: "Authorization header missing" }, status: :unauthorized
      return
    end

    payload = verify_clerk_token(token)
    unless payload
      render json: { error: "Invalid or expired token" }, status: :unauthorized
      return
    end

    clerk_id = payload["sub"]
    @current_user = User.find_by(clerk_id: clerk_id)

    unless @current_user
      # Auto-provision user from Clerk token data
      @current_user = provision_user_from_clerk(payload)
    end

    unless @current_user
      render json: { error: "User not found" }, status: :unauthorized
    end
  end

  def extract_token
    header = request.headers["Authorization"]
    return nil unless header&.start_with?("Bearer ")
    header.split(" ").last
  end

  def verify_clerk_token(token)
    jwks = fetch_jwks
    return nil unless jwks

    # Decode without verification first to get the key ID
    unverified = JWT.decode(token, nil, false)
    kid = unverified[1]["kid"]

    # Find the matching key
    jwk = jwks.find { |k| k["kid"] == kid }
    return nil unless jwk

    # Build the RSA key and verify
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
      # Keep compatibility with Clerk setups that don't emit aud.
      options[:verify_aud] = false
    end

    decoded = JWT.decode(token, key, true, options)
    decoded[0]
  rescue JWT::DecodeError, JWT::ExpiredSignature, JWT::InvalidIssuerError => e
    Rails.logger.warn("Clerk JWT verification failed: #{e.message}")
    nil
  end

  def fetch_jwks
    Rails.cache.fetch("clerk_jwks", expires_in: 1.hour) do
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
    rescue Timeout::Error, Errno::ECONNREFUSED => e
      Rails.logger.error("Network error fetching Clerk JWKS: #{e.message}")
      nil
    end
  end

  def clerk_issuer
    # Use explicit env var if set (supports custom domains / production instances)
    # Falls back to constructing from instance ID for dev environments
    ENV.fetch("CLERK_ISSUER") { "https://#{clerk_instance_id}.clerk.accounts.dev" }
  end

  def clerk_api_base
    ENV.fetch("CLERK_API_BASE") { "https://#{clerk_instance_id}.clerk.accounts.dev" }
  end

  def clerk_audience
    ENV["CLERK_AUDIENCE"]
  end

  def clerk_instance_id
    # Extract from publishable key or use env var
    ENV.fetch("CLERK_INSTANCE_ID") do
      pk = ENV["CLERK_PUBLISHABLE_KEY"] || ""
      # pk_test_<base64 of instance>.clerk.accounts.dev$
      decoded = Base64.decode64(pk.sub(/^pk_(test|live)_/, ""))
      decoded.split(".clerk.accounts.dev").first
    end
  end

  def provision_user_from_clerk(payload)
    # Fetch user details from Clerk API
    clerk_user = fetch_clerk_user(payload["sub"])
    return nil unless clerk_user

    email = clerk_user.dig("email_addresses", 0, "email_address")&.strip&.downcase
    return nil unless email

    # Check if user exists by email (could have been invited before signing up)
    # Use transaction + retry to handle race conditions on concurrent requests
    user = User.find_by("LOWER(email) = ?", email)
    if user
      user.update!(clerk_id: payload["sub"])
      return user
    end

    invitation = UserInvitation.active.where("LOWER(email) = ?", email).order(invited_at: :desc).first
    return nil unless invitation

    User.transaction do
      new_user = User.create!(
        email: email,
        name: [clerk_user["first_name"], clerk_user["last_name"]].compact.join(" ").presence || invitation.name || email,
        clerk_id: payload["sub"],
        company_id: invitation.company_id,
        role: invitation.role
      )
      invitation.accept!
      new_user
    end
  rescue ActiveRecord::RecordNotUnique
    # Race condition: another request created the user first, find and update
    user = User.find_by("LOWER(email) = ?", email)
    user&.update!(clerk_id: payload["sub"]) if user&.clerk_id.blank?
    user
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("Failed to provision Clerk user: #{e.message}")
    nil
  end

  def fetch_clerk_user(clerk_id)
    uri = URI("https://api.clerk.com/v1/users/#{clerk_id}")
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{ENV['CLERK_SECRET_KEY']}"

    response = http.request(req)

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      Rails.logger.error("Failed to fetch Clerk user: #{response.code}")
      nil
    end
  rescue Timeout::Error, Errno::ECONNREFUSED => e
    Rails.logger.error("Network error fetching Clerk user: #{e.message}")
    nil
  end

  def current_user
    @current_user
  end

  def current_company
    @current_company ||= current_user&.company
  end

  def current_company_id
    current_user&.company_id
  end
end
