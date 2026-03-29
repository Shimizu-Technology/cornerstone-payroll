# frozen_string_literal: true

class ClerkInvitationService
  BASE_URL = "https://api.clerk.com/v1"

  def initialize
    @secret_key = ENV["CLERK_SECRET_KEY"]
  end

  def configured?
    @secret_key.present?
  end

  def create_invitation(email:, redirect_url: nil, public_metadata: {}, ignore_existing: false)
    raise "CLERK_SECRET_KEY not configured" unless configured?

    body = {
      email_address: email,
      notify: false,
      ignore_existing: ignore_existing
    }
    body[:redirect_url] = redirect_url if redirect_url.present?
    body[:public_metadata] = public_metadata if public_metadata.present?

    Rails.logger.info("[ClerkInvitation] Creating invitation for #{email}")

    response = post_json("/invitations", body)

    if response.is_a?(Net::HTTPSuccess)
      parsed = JSON.parse(response.body)
      Rails.logger.info("[ClerkInvitation] Created for #{email}: id=#{parsed['id']} status=#{parsed['status']}")
      { success: true, invitation_id: parsed["id"], status: parsed["status"], url: parsed["url"] }
    else
      error_message = extract_error_message(response)
      Rails.logger.error("[ClerkInvitation] Failed for #{email}: #{error_message}")
      { success: false, error: error_message, status_code: response.code.to_i }
    end
  rescue Timeout::Error, Errno::ECONNREFUSED => e
    Rails.logger.error("[ClerkInvitation] Network error for #{email}: #{e.message}")
    { success: false, error: "Could not reach Clerk API: #{e.message}" }
  end

  def revoke_invitation(invitation_id)
    raise "CLERK_SECRET_KEY not configured" unless configured?

    response = post_json("/invitations/#{invitation_id}/revoke", {})

    if response.is_a?(Net::HTTPSuccess)
      { success: true }
    else
      { success: false, error: extract_error_message(response) }
    end
  rescue Timeout::Error, Errno::ECONNREFUSED => e
    { success: false, error: e.message }
  end

  private

  def post_json(path, body)
    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 10

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{@secret_key}"
    req["Content-Type"] = "application/json"
    req.body = body.to_json

    http.request(req)
  end

  def extract_error_message(response)
    parsed = JSON.parse(response.body) rescue {}

    if parsed["errors"].is_a?(Array) && parsed["errors"].any?
      parsed["errors"].map { |e| e["long_message"] || e["message"] }.join("; ")
    else
      parsed["message"] || "Clerk API error (#{response.code})"
    end
  end
end
