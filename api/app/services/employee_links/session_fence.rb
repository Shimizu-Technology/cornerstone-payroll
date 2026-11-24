# frozen_string_literal: true

module EmployeeLinks
  # Sessions from before an employee-only login was deactivated stay refused
  # for good, even after the login is reactivated (M4-2, D12): a token counts
  # only if its Clerk session was created after users.deactivated_at.
  #
  # The session's creation time is Clerk's own, immutable created_at, read
  # from the Backend API (GET /sessions/{sid}) for the verified token's sid
  # and cached per sid. deactivated_at is the database's clock at the actual
  # closure, under the login's lock. If the creation time can't be read, or
  # the session isn't this token's user's, the token is refused, for fenced
  # logins only; every other login never calls Clerk here.
  #
  # Recent verification (step-up) is a separate requirement, checked by the
  # callers that need it (MfaPolicy).
  module SessionFence
    CACHE_PREFIX = "employee_links/session_created_at/v1"
    # Longer than any Clerk session lives; the value never changes.
    CACHE_TTL = 90.days

    module_function

    def fenced?(user, payload, clerk: nil)
      return false unless user&.portal_employee? && user.deactivated_at

      created_at = session_created_at(payload, clerk: clerk)
      created_at.nil? || created_at <= user.deactivated_at
    end

    # When Clerk created the token's session, or nil.
    def session_created_at(payload, clerk: nil)
      return unless payload.is_a?(Hash)

      sid = payload["sid"]
      subject = payload["sub"]
      return unless sid.is_a?(String) && ClerkInvitationService::SESSION_PATTERN.match?(sid) && subject.is_a?(String)

      key = "#{CACHE_PREFIX}/#{sid}"
      cached = Rails.cache.read(key)
      millis = cached["created_at"] if cached.is_a?(Hash) && cached["user_id"] == subject
      millis ||= fetch_created_at(sid, subject, key, clerk || ClerkInvitationService.new)
      Time.zone.at(Rational(millis, 1000)) if millis
    end

    def fetch_created_at(sid, subject, key, clerk)
      session = clerk.fetch_session(sid)
      return unless session.is_a?(Hash) && session["id"] == sid && session["user_id"] == subject
      return unless session["created_at"].is_a?(Integer) && session["created_at"].positive?

      Rails.cache.write(key, { "user_id" => subject, "created_at" => session["created_at"] }, expires_in: CACHE_TTL)
      session["created_at"]
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::SessionFence] Could not read session #{sid}: #{error.class}")
      nil
    end
    private_class_method :fetch_created_at
  end
end
