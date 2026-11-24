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
  #
  # Clerk's clock and the database's can disagree, so a session Clerk says
  # began up to SESSION_SKEW_ALLOWANCE after the closure counts as from
  # before it: RevokeEmployeeSessionsJob ends those sessions too, and the
  # fence refuses them. Someone who signed in within that window signs in
  # again; reactivation comes long after a closure, so that costs nothing.
  #
  # Only a successful lookup is cached for long. A failed one is remembered
  # for NEGATIVE_CACHE_TTL, so a token that keeps failing doesn't call Clerk
  # on every request; it stays refused meanwhile.
  module SessionFence
    SESSION_SKEW_ALLOWANCE = 5.minutes
    CACHE_PREFIX = "employee_links/session_created_at/v1"
    FAILED_PREFIX = "employee_links/session_created_at_failed/v1"
    # Longer than any Clerk session lives; the value never changes.
    CACHE_TTL = 90.days
    NEGATIVE_CACHE_TTL = 30.seconds
    SIGN_IN_AGAIN = { error: "Sign in again to continue", code: "session_predates_reactivation" }.freeze

    module_function

    def fenced?(user, payload, clerk: nil)
      return false unless user&.portal_employee? && user.deactivated_at

      created_at = session_created_at(payload, clerk: clerk)
      created_at.nil? || created_at <= cutoff(user.deactivated_at)
    end

    # Sessions Clerk created at or before this time predate a closure at
    # closed_at (the fence and the revocation job share it).
    def cutoff(closed_at)
      closed_at + SESSION_SKEW_ALLOWANCE
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
      return Time.zone.at(Rational(millis, 1000)) if millis

      failed_key = "#{FAILED_PREFIX}/#{sid}/#{Digest::SHA256.hexdigest(subject)}"
      return if Rails.cache.read(failed_key)

      millis = fetch_created_at(sid, subject, key, clerk || ClerkInvitationService.new)
      return Time.zone.at(Rational(millis, 1000)) if millis

      remember_failure(failed_key)
      nil
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

    def remember_failure(failed_key)
      Rails.cache.write(failed_key, true, expires_in: NEGATIVE_CACHE_TTL)
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::SessionFence] Could not cache a failed session lookup: #{error.class}")
    end
    private_class_method :fetch_created_at, :remember_failure
  end
end
