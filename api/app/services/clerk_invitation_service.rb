# frozen_string_literal: true

class ClerkInvitationService
  BASE_URL = "https://api.clerk.com/v1"
  SUBJECT_PATTERN = /\Auser_[a-zA-Z0-9_-]+\z/

  def initialize
    @secret_key = ENV["CLERK_SECRET_KEY"]
  end

  def configured?
    @secret_key.present?
  end

  def create_invitation(email:, redirect_url: nil, public_metadata: {}, ignore_existing: false)
    StagingOutboundPolicy.clerk_target!(email: email)
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
      parsed = parse_body(response)
      return { success: false, error: "Clerk did not return an invitation ID" } if parsed["id"].blank?

      Rails.logger.info("[ClerkInvitation] Created for #{email}: id=#{parsed['id']} status=#{parsed['status']}")
      { success: true, invitation_id: parsed["id"], status: parsed["status"], url: parsed["url"] }
    else
      error_message = extract_error_message(response)
      nonce = public_metadata[:payroll_invite_nonce]
      error_message = error_message.gsub(nonce, "[FILTERED]") if nonce.present?
      Rails.logger.error("[ClerkInvitation] Failed for #{email}: #{error_message}")
      { success: false, error: error_message, status_code: response.code.to_i }
    end
  rescue Timeout::Error, SystemCallError, SocketError, EOFError, OpenSSL::SSL::SSLError, JSON::ParserError => e
    Rails.logger.error("[ClerkInvitation] Clerk request failed: #{e.class}")
    { success: false, error: "Could not reach Clerk API" }
  end

  def fetch_user(subject)
    return unless subject.is_a?(String) && SUBJECT_PATTERN.match?(subject)

    data = get_json("/users/#{subject}")
    data if data.is_a?(Hash) && data["id"] == subject
  end

  def invitation_status(invitation_id)
    return if invitation_id.blank?

    # Clerk exposes lookup by ID as a filter on the list endpoint.
    query = URI.encode_www_form(query: invitation_id, limit: 10)
    invitation = find_invitation("/invitations?#{query}", invitation_id) ||
      find_invitation("/invitations?#{query}&status=revoked", invitation_id)
    invitation&.fetch("status", nil)
  end

  def revoke_invitation(invitation_id)
    if StagingOutboundPolicy.staging?
      StagingOutboundPolicy.clerk_target!(email: User.find_by(clerk_invitation_id: invitation_id)&.email)
    end
    raise "CLERK_SECRET_KEY not configured" unless configured?

    response = post_json("/invitations/#{invitation_id}/revoke", {})

    if response.is_a?(Net::HTTPSuccess)
      { success: true }
    else
      error = Array(parse_body(response)["errors"]).first
      { success: false, error: extract_error_message(response), status: response.code.to_i,
        error_code: error.is_a?(Hash) ? error["code"] : nil }
    end
  rescue Timeout::Error, SystemCallError, SocketError, EOFError, OpenSSL::SSL::SSLError, JSON::ParserError => e
    { success: false, error: e.message }
  end

  private

  def find_invitation(path, id)
    data = get_json(path)
    invitations = data.is_a?(Hash) ? data["data"] : data
    return unless invitations.is_a?(Array)

    invitations.find { |invitation| invitation.is_a?(Hash) && invitation["id"] == id }
  end

  def get_json(path)
    return unless configured?

    response = request_json(path, Net::HTTP::Get)
    JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
  rescue Timeout::Error, SystemCallError, SocketError, EOFError, OpenSSL::SSL::SSLError, JSON::ParserError => e
    Rails.logger.warn("[ClerkInvitation] Clerk lookup failed: #{e.class}")
    nil
  end

  def post_json(path, body)
    request_json(path, Net::HTTP::Post, body)
  end

  def request_json(path, method, body = nil)
    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5

    req = method.new(uri)
    req["Authorization"] = "Bearer #{@secret_key}"
    req["Content-Type"] = "application/json"
    req.body = body.to_json if body

    http.request(req)
  end

  def parse_body(response)
    parsed = JSON.parse(response.body)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def extract_error_message(response)
    parsed = parse_body(response)

    if parsed["errors"].is_a?(Array) && parsed["errors"].any?
      parsed["errors"].map { |e| e["long_message"] || e["message"] }.join("; ")
    else
      parsed["message"] || "Clerk API error (#{response.code})"
    end
  end
end
