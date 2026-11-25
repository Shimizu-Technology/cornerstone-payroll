# frozen_string_literal: true

class ClerkInvitationService
  BASE_URL = "https://api.clerk.com/v1"
  INVITATION_LOOKUP_OFFSET_LIMIT = 100
  SUBJECT_PATTERN = /\Auser_[a-zA-Z0-9_-]+\z/
  DEADLINE_KEY = :clerk_pass_deadline

  # The most one Clerk call may take from connecting to its last byte, and
  # the most body it may send. Within a pass deadline the call gets only the
  # time left before it, if that is less.
  REQUEST_BUDGET = 30.seconds
  MAX_RESPONSE_BYTES = 5.megabytes
  SOCKET_TIMEOUT = 5

  # A pass ran out of time: raised instead of starting a Clerk call after
  # the deadline set by within_deadline, or when a call in flight runs into
  # it. Deliberately not one of the network errors the calls below rescue,
  # so it ends the whole pass.
  class DeadlineReached < StandardError; end
  # One Clerk call used up its own budget (REQUEST_BUDGET) or sent more
  # than MAX_RESPONSE_BYTES. Both are request failures the calls below
  # rescue and fail closed on.
  class RequestBudgetExceeded < Timeout::Error; end
  class ResponseTooLarge < IOError; end

  REQUEST_ERRORS = [ Timeout::Error, SystemCallError, SocketError, EOFError, ResponseTooLarge,
                     OpenSSL::SSL::SSLError, JSON::ParserError ].freeze

  # Runs the block with a deadline for this thread's Clerk calls (the
  # earlier one, when nested): a call that would start after it raises
  # DeadlineReached instead, and a call in flight is cut off at it (see
  # request_json), so a pass never runs past its deadline.
  def self.within_deadline(deadline)
    previous = Thread.current[DEADLINE_KEY]
    Thread.current[DEADLINE_KEY] = [ previous, deadline ].compact.min
    yield
  ensure
    Thread.current[DEADLINE_KEY] = previous
  end

  def initialize
    @secret_key = ENV["CLERK_SECRET_KEY"]
  end

  def configured?
    @secret_key.present?
  end

  def create_invitation(email:, redirect_url: nil, public_metadata: {}, ignore_existing: false)
    scope = DemoOutbound.scope_company
    if scope && !DemoOutbound.permit?(company: scope, email: email, channel: "clerk_invitation")
      return { success: false, error: Company::DEMO_RECIPIENT_REFUSED_MESSAGE, refused: :recipient_not_allowed }
    end
    StagingOutboundPolicy.clerk_target!(email: email)
    raise "CLERK_SECRET_KEY not configured" unless configured?

    body = {
      email_address: email,
      notify: false,
      ignore_existing: ignore_existing
    }
    body[:redirect_url] = redirect_url if redirect_url.present?
    body[:public_metadata] = public_metadata if public_metadata.present?

    Rails.logger.info("[ClerkInvitation] Creating invitation for #{LogRedaction.email(email)}")

    response = post_json("/invitations", body)

    if response.is_a?(Net::HTTPSuccess)
      parsed = parse_body(response)
      return { success: false, error: "Clerk did not return an invitation ID" } if parsed["id"].blank?

      Rails.logger.info("[ClerkInvitation] Created for #{LogRedaction.email(email)}: id=#{parsed['id']} status=#{parsed['status']}")
      { success: true, invitation_id: parsed["id"], status: parsed["status"], url: parsed["url"] }
    else
      error_message = extract_error_message(response)
      nonce = public_metadata[:payroll_invite_nonce]
      error_message = error_message.gsub(nonce, "[FILTERED]") if nonce.present?
      error_code = extract_error_code(response)
      # Clerk's text can repeat the address, so the log keeps only its code.
      Rails.logger.error("[ClerkInvitation] Failed for #{LogRedaction.email(email)}: status=#{response.code} code=#{error_code || 'none'}")
      { success: false, error: error_message, status_code: response.code.to_i, error_code: error_code }
    end
  rescue *REQUEST_ERRORS => e
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

    { id: subject, name: user.values_at("first_name", "last_name").compact_blank.join(" ").presence }
      .merge(self.class.email_summary(user).slice(:verified_emails, :primary_email))
  end

  # A Clerk user's addresses: the primary one, the verified ones, and how
  # each verified one was verified (Clerk's strategy, e.g. "email_code" or
  # "ticket"), keyed by the lowercased address.
  def self.email_summary(user)
    entries = Array(user.is_a?(Hash) ? user["email_addresses"] : nil).select do |entry|
      entry.is_a?(Hash) && entry["email_address"].is_a?(String) && entry["email_address"].present?
    end
    primary_id = user["primary_email_address_id"] if user.is_a?(Hash)
    primary = entries.find { |entry| entry["id"] == primary_id } if primary_id.present?
    verified = entries.select { |entry| entry.dig("verification", "status") == "verified" }
    {
      primary_email: primary&.fetch("email_address"),
      primary_verified: primary.present? && primary.dig("verification", "status") == "verified",
      verified_emails: verified.map { |entry| entry["email_address"] },
      verification_strategies: verified.to_h { |entry| [ entry["email_address"].downcase, entry.dig("verification", "strategy").to_s ] }
    }
  end

  SESSION_PATTERN = /\Asess_[a-zA-Z0-9_-]+\z/
  SESSION_PAGE_LIMIT = 100
  # 20 pages of 100. A user with more active sessions than that is listed and
  # revoked a page cap at a time: the pass reports failure, so the caller
  # retries until a pass finds nothing left.
  SESSION_PAGE_CAP = 20

  # Ends a user's active Clerk sessions (D12): every one, or with
  # created_before only those Clerk reports as created at or before that time
  # (a session without a creation time is ended too).
  #
  # Every page of the user's active sessions is listed before any is revoked.
  # A session that already ended (or is gone, 404) counts as revoked. Success
  # means one full pass: the whole list was read, every targeted session was
  # revoked, and a fresh listing finds none of them still active. Returns
  # { success:, revoked: } and never raises for a Clerk or network failure.
  #
  # email: in staging, the named tester address this user was made for (an
  # unbound sign-up has no tester binding yet).
  def revoke_user_sessions(subject, created_before: nil, email: nil)
    return { success: false, error: "Invalid Clerk user ID" } unless valid_subject?(subject)

    staging_target!(subject, email)
    return { success: false, error: "CLERK_SECRET_KEY not configured" } unless configured?

    cutoff = created_before && (created_before.to_f * 1000).floor
    listing = active_sessions(subject)
    return { success: false, error: listing[:error] } if listing[:error]

    revoked = 0
    targeted(listing[:sessions], cutoff).each do |session|
      return { success: false, error: "Clerk refused a session revocation", revoked: revoked } unless end_session(session["id"])

      revoked += 1
    end
    return { success: false, error: "Too many Clerk sessions for one pass", revoked: revoked } unless listing[:complete]

    # The confirming pass must see every page too, or a targeted session
    # past the cap could still be active.
    recheck = active_sessions(subject)
    return { success: false, error: recheck[:error], revoked: revoked } if recheck[:error]
    return { success: false, error: "Too many Clerk sessions to confirm in one pass", revoked: revoked } unless recheck[:complete]
    return { success: false, error: "Sessions were still active after revocation", revoked: revoked } if
      targeted(recheck[:sessions], cutoff).any?

    { success: true, revoked: revoked }
  rescue *REQUEST_ERRORS => e
    { success: false, error: e.class.name }
  end

  # A Clerk session (its id, user_id, status, created_at), or nil.
  def fetch_session(session_id)
    return unless session_id.is_a?(String) && SESSION_PATTERN.match?(session_id)

    data = get_json("/sessions/#{session_id}")
    data if data.is_a?(Hash) && data["id"] == session_id
  end

  # The Clerk users that have this address, or nil when Clerk can't be asked.
  def users_with_email(email)
    return unless configured? && email.is_a?(String) && email.present?

    data = get_json("/users?#{URI.encode_www_form(email_address: email, limit: 100)}")
    data = data["data"] if data.is_a?(Hash)
    return unless data.is_a?(Array) && data.all? { |user| user.is_a?(Hash) && valid_subject?(user["id"]) }

    data
  end

  # Deletes a Clerk user (one already gone counts as deleted). email: the
  # address it was made for, for the staging tester gate.
  def delete_user(subject, email:)
    return { success: false, error: "Invalid Clerk user ID" } unless valid_subject?(subject)

    StagingOutboundPolicy.clerk_target!(email: email)
    return { success: false, error: "CLERK_SECRET_KEY not configured" } unless configured?

    response = request_json("/users/#{subject}", Net::HTTP::Delete)
    return { success: true } if response.is_a?(Net::HTTPSuccess) || response.code.to_i == 404

    { success: false, error: extract_error_message(response), status: response.code.to_i }
  rescue *REQUEST_ERRORS => e
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
  rescue *REQUEST_ERRORS => e
    { success: false, error: e.message }
  end

  private

  def valid_subject?(subject)
    subject.is_a?(String) && SUBJECT_PATTERN.match?(subject)
  end

  def staging_target!(subject, email)
    return unless StagingOutboundPolicy.staging?

    email ? StagingOutboundPolicy.clerk_target!(email: email) : StagingOutboundPolicy.clerk_target!(id: subject)
  end

  def targeted(sessions, cutoff)
    sessions.reject { |session| cutoff && session["created_at"].is_a?(Integer) && session["created_at"] > cutoff }
  end

  # Every page of the user's active sessions, up to SESSION_PAGE_CAP pages.
  # { sessions:, complete: } or { error: }.
  def active_sessions(subject)
    sessions = []
    SESSION_PAGE_CAP.times do |page|
      query = { user_id: subject, status: "active", limit: SESSION_PAGE_LIMIT }
      query[:offset] = page * SESSION_PAGE_LIMIT if page.positive?
      data = get_json("/sessions?#{URI.encode_www_form(query)}")
      data = data["data"] if data.is_a?(Hash)
      return { error: "Could not list Clerk sessions" } unless data.is_a?(Array)

      sessions.concat(data.select { |session| session.is_a?(Hash) && SESSION_PATTERN.match?(session["id"].to_s) })
      return { sessions: sessions.uniq { |session| session["id"] }, complete: true } if data.length < SESSION_PAGE_LIMIT
    end
    Rails.logger.error("[ClerkInvitation] SESSION PAGE CAP HIT: Clerk user #{subject} has more than " \
      "#{SESSION_PAGE_CAP * SESSION_PAGE_LIMIT} active sessions; revoking these and retrying")
    { sessions: sessions.uniq { |session| session["id"] }, complete: false }
  end

  # True once the session is no longer active: revoked now, already ended,
  # or gone.
  def end_session(session_id)
    response = post_json("/sessions/#{session_id}/revoke", {})
    return true if response.is_a?(Net::HTTPSuccess) || response.code.to_i == 404

    session = get_json("/sessions/#{session_id}")
    session.is_a?(Hash) && session["id"] == session_id && session["status"].is_a?(String) && session["status"] != "active"
  end

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
  rescue *REQUEST_ERRORS => e
    Rails.logger.warn("[ClerkInvitation] Clerk lookup failed: #{e.class}")
    nil
  end

  def post_json(path, body)
    request_json(path, Net::HTTP::Post, body)
  end

  # One Clerk call, bounded as a whole: the connection, the request, and
  # the response down to its last byte must finish within its budget (the
  # time left before the pass deadline, at most REQUEST_BUDGET), however
  # slowly Clerk trickles it in, and the body may not pass
  # MAX_RESPONSE_BYTES. Running out of the pass deadline raises
  # DeadlineReached so the pass is rescheduled; running out of the call's
  # own budget, or an oversized body, is a request failure.
  def request_json(path, method, body = nil)
    deadline = Thread.current[DEADLINE_KEY]
    raise DeadlineReached, "Clerk pass deadline reached" if deadline && Time.current >= deadline

    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = true

    req = method.new(uri)
    req["Authorization"] = "Bearer #{@secret_key}"
    req["Content-Type"] = "application/json"
    req.body = body.to_json if body

    pass_bound = false
    # Validate staging Clerk policy (which runs User.find_by queries in staging)
    # before entering Timeout.timeout so an async timeout cannot interrupt
    # ActiveRecord I/O. StagingHttpGuard still runs http_host! on every request
    # and connect, and skips only the duplicate clerk_request! DB query for
    # this exact request object.
    StagingOutboundPolicy.with_preauthorized_clerk_request(req) do
      started = Time.current
      raise DeadlineReached, "Clerk pass deadline reached" if deadline && started >= deadline

      budget = REQUEST_BUDGET.to_f
      pass_bound = deadline && (deadline - started) <= budget
      budget = (deadline - started).to_f if pass_bound
      http.open_timeout = http.read_timeout = http.write_timeout = [ SOCKET_TIMEOUT, budget ].min

      # The same shape as TimeTracking::Client#read_response: per-read timeouts
      # reset on each chunk, so the whole call is capped too, with a
      # Timeout::Error subclass the callers already rescue.
      Timeout.timeout(budget, RequestBudgetExceeded, "Clerk request budget exceeded") do
        http.request(req) do |response|
          declared = response["Content-Length"].presence&.to_i
          raise ResponseTooLarge, "Clerk response exceeded #{MAX_RESPONSE_BYTES} bytes" if declared&.>(MAX_RESPONSE_BYTES)

          response.read_body(BoundedBody.new(MAX_RESPONSE_BYTES))
        end
      end
    end
  rescue Timeout::Error => e
    # Cut off at the pass deadline (by the budget, or a socket timeout that
    # the deadline shortened): the pass ends and is rescheduled.
    raise DeadlineReached, "Clerk pass deadline reached" if
      pass_bound && (e.is_a?(RequestBudgetExceeded) || Time.current >= deadline)

    raise
  end

  # A response body that refuses to grow past its limit as it streams in.
  class BoundedBody < String
    def initialize(limit)
      super()
      @limit = limit
    end

    def <<(chunk)
      raise ResponseTooLarge, "Clerk response exceeded #{@limit} bytes" if bytesize + chunk.bytesize > @limit

      super
    end
  end
  private_constant :BoundedBody

  def parse_body(response)
    parsed = JSON.parse(response.body)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def extract_error_code(response)
    errors = parse_body(response)["errors"]
    code = errors.first["code"] if errors.is_a?(Array) && errors.first.is_a?(Hash)
    code if code.is_a?(String) && code.match?(/\A[a-z0-9_]{1,64}\z/)
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
