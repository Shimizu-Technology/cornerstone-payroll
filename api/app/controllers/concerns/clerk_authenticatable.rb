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

    @clerk_token_payload = verify_clerk_token(token)
    unless @clerk_token_payload
      render json: { error: "Invalid or expired token" }, status: :unauthorized
      return
    end

    clerk_id = @clerk_token_payload["sub"]
    @current_user = User.find_by(clerk_id: clerk_id)

    if StagingOutboundPolicy.staging? && !StagingOutboundPolicy.bindings.value?(clerk_id)
      render json: { error: "Staging access is restricted to named testers" }, status: :forbidden
      return
    end

    if StagingOutboundPolicy.staging? && !@current_user
      render json: { error: "Staging tester has not been explicitly bound" }, status: :forbidden
      return
    end

    unless @current_user
      # Auto-provision user from Clerk token data
      @current_user = provision_user_from_clerk(@clerk_token_payload)
    end

    unless @current_user
      render json: { error: "User not found" }, status: :unauthorized
      return
    end

    unless StagingOutboundPolicy.tester?(user_id: @current_user.id, email: @current_user.email, id: clerk_id)
      @current_user = nil
      render json: { error: "Staging tester binding does not match" }, status: :forbidden
      return
    end

    unless @current_user.payroll_access_allowed?
      @current_user = nil
      render json: { error: "Account inactive" }, status: :unauthorized
    end
  end

  def extract_token
    header = request.headers["Authorization"]
    return nil unless header&.start_with?("Bearer ")
    header.split(" ").last
  end

  def verify_clerk_token(token)
    clerk_token_verifier.verify(token)
  end

  def clerk_token_verifier
    @clerk_token_verifier ||= ClerkTokenVerifier.new
  end

  def provision_user_from_clerk(payload)
    # Fetch user details from Clerk API
    clerk_user = fetch_clerk_user(payload["sub"])
    return nil unless clerk_user

    email = verified_primary_email(clerk_user)
    return nil unless email
    clerk_name = [ clerk_user["first_name"], clerk_user["last_name"] ].compact.join(" ").presence

    # Check if user exists by email (invited user signing in for first time)
    user = User.find_by("LOWER(email) = ?", email)
    if user
      attrs = { clerk_id: payload["sub"] }
      attrs[:organization_id] = Company.where(id: user.company_id).pick(:organization_id) if user.organization_id.blank? && user.company_id.present?
      attrs[:invitation_status] = "accepted" if user.invitation_pending?
      attrs[:name] = clerk_name if clerk_name.present?
      user.update!(attrs)
      return user
    end

    invitation = UserInvitation.active.where("LOWER(email) = ?", email).order(invited_at: :desc).first
    return bootstrap_first_user!(payload, email, clerk_name) if initial_admin_bootstrap_allowed?(email)
    return nil unless invitation

    User.transaction do
      new_user = User.create!(
        email: email,
        name: clerk_name || invitation.name || email,
        clerk_id: payload["sub"],
        company_id: invitation.company_id,
        organization: invitation.company.organization,
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

  def verified_primary_email(clerk_user)
    primary_email_id = clerk_user["primary_email_address_id"]
    return nil if primary_email_id.blank?

    primary_email = Array(clerk_user["email_addresses"]).find do |address|
      address["id"] == primary_email_id
    end
    return nil unless primary_email&.dig("verification", "status") == "verified"

    primary_email["email_address"]&.strip&.downcase.presence
  end

  def bootstrap_first_user!(payload, email, clerk_name)
    return nil if User.exists?

    User.transaction do
      organization = Organization.find_or_create_by!(slug: "cornerstone-tax-services") do |org|
        org.name = "Cornerstone Tax Services"
        org.status = "active"
      end
      company = Company.order(:id).first || Company.create!(name: "Cornerstone Payroll", organization: organization)
      company.update!(organization: organization) if company.organization_id.blank?

      User.create!(
        email: email,
        name: clerk_name || email,
        clerk_id: payload["sub"],
        company: company,
        organization: company.organization,
        role: email.casecmp?(User::PRIMARY_PLATFORM_OWNER_EMAIL) ? "super_admin" : "admin",
        platform_owner: email.casecmp?(User::PRIMARY_PLATFORM_OWNER_EMAIL),
        invitation_status: "accepted"
      )
    end.tap do |user|
      Rails.logger.warn("Bootstrapped first production admin #{user.email}")
    end
  end

  def initial_admin_bootstrap_allowed?(email)
    return false if User.exists?

    allowed_emails = ENV.fetch("INITIAL_ADMIN_EMAILS", "")
                        .split(",")
                        .map { |value| value.strip.downcase }
                        .reject(&:blank?)

    return true if allowed_emails.include?(email)

    ENV["ALLOW_INITIAL_ADMIN_BOOTSTRAP"] == "true"
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
end
