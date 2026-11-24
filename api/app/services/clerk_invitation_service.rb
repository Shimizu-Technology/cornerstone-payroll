# frozen_string_literal: true

class ClerkInvitationService
  BASE_URL = "https://api.clerk.com/v1"
  INVITATION_LOOKUP_OFFSET_LIMIT = 100
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

  def recovery_account(subject)
    user = fetch_user(subject)
    return unless user

    emails = Array(user["email_addresses"]).select do |entry|
      entry.is_a?(Hash) && entry["email_address"].is_a?(String) && entry["email_address"].present?
    end
    primary = emails.find { |entry| entry["id"] == user["primary_email_address_id"] } if user["primary_email_address_id"].present?
    {
      id: subject,
      name: user.values_at("first_name", "last_name").compact_blank.join(" ").presence,
      verified_emails: emails.filter_map { |entry| entry["email_address"] if entry.dig("verification", "status") == "verified" },
      primary_email: primary&.fetch("email_address")
    }
  end

  # Ends every active Clerk session for a user (D12). Returns
  # { success:, revoked: } and never raises for a Clerk or network failure.
  def revoke_user_sessions(subject)
    return { success: false, error: "Invalid Clerk user ID" } unless subject.is_a?(String) && SUBJECT_PATTERN.match?(subject)
    if StagingOutboundPolicy.staging? && !StagingOutboundPolicy.bindings.value?(subject)
      raise StagingOutboundPolicy::Blocked, "Staging Clerk session revocation is limited to bound testers"
    end
    return { success: false, error: "CLERK_SECRET_KEY not configured" } unless configured?

    sessions = get_json("/sessions?#{URI.encode_www_form(user_id: subject, status: 'active', limit: 100)}")
    sessions = sessions["data"] if sessions.is_a?(Hash)
    return { success: false, error: "Could not list Clerk sessions" } unless sessions.is_a?(Array)

    revoked = 0
    sessions.each do |session|
      next unless session.is_a?(Hash) && session["id"].to_s.match?(/\Asess_[a-zA-Z0-9_-]+\z/)

      response = post_json("/sessions/#{session['id']}/revoke", {})
      return { success: false, error: "Clerk refused a session revocation", revoked: revoked } unless response.is_a?(Net::HTTPSuccess)

      revoked += 1
    end
    { success: true, revoked: revoked }
  rescue Timeout::Error, SystemCallError, SocketError, EOFError, OpenSSL::SSL::SSLError, JSON::ParserError => e
    { success: false, error: e.class.name }
  end

  def invitation_status(invitation_id)
    return if invitation_id.blank?

    # The unfiltered list excludes revoked invites. Also query expired explicitly
    # so a default response that omits expired invites still resolves their status.
    [ nil, "revoked", "expired" ].each do |status|
      invitation = find_invitation(invitation_id, status: status)
      return invitation&.fetch("status", nil) unless invitation == :not_found
    end
    :not_found
  end

  def revoke_invitation(invitation_id, email: nil)
    response = request_revocation(invitation_id, email: email)

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

  def request_revocation(invitation_id, email:)
    previous = Thread.current[:staging_clerk_revoke_target]
    if StagingOutboundPolicy.staging?
      unless invitation_id.to_s.match?(/\Ainv_[a-zA-Z0-9_-]+\z/)
        raise StagingOutboundPolicy::Blocked, "Invalid staging Clerk invitation ID"
      end
      email ||= User.find_by(clerk_invitation_id: invitation_id)&.email
      StagingOutboundPolicy.clerk_target!(email: email)
      Thread.current[:staging_clerk_revoke_target] = { invitation_id: invitation_id, email: email }
    end
    raise "CLERK_SECRET_KEY not configured" unless configured?

    post_json("/invitations/#{invitation_id}/revoke", {})
  ensure
    Thread.current[:staging_clerk_revoke_target] = previous
  end

  def find_invitation(id, status:)
    limit = 10
    offset = 0
    while offset < INVITATION_LOOKUP_OFFSET_LIMIT
      filters = { query: id, limit: limit, status: status }.compact
      filters[:offset] = offset if offset.positive?
      data = get_json("/invitations?#{URI.encode_www_form(filters)}")
      invitations = data.is_a?(Hash) ? data["data"] : data
      return unless invitations.is_a?(Array) && invitations.all? { |invitation| invitation.is_a?(Hash) && invitation["id"].present? }

      match = invitations.find { |invitation| invitation["id"] == id }
      return match if match

      total = data["total_count"] if data.is_a?(Hash)
      offset += invitations.length
      return :not_found if invitations.empty? || (total.is_a?(Integer) ? offset >= total : invitations.length < limit)
    end
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
