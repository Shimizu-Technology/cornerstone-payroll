# frozen_string_literal: true

class MfaPolicy
  class VerificationRequired < StandardError; end

  ERROR_MESSAGE = "Multi-factor authentication is required before accessing payroll."
  ERROR_CODE = "mfa_required"
  ENROLLMENT_REQUIRED_CODE = "mfa_enrollment_required"
  ENROLLMENT_REQUIRED_MESSAGE = "Set up two-step sign-in before accessing payroll."
  STEP_UP_MAX_AGE_MINUTES = 10
  ENROLLMENT_CLAIM = "two_factor_enabled"
  TRUTHY_VALUES = %w[1 true t yes y on].freeze

  # REQUIRE_MFA is the one switch. Off (unset or false), nobody needs a second
  # factor and step-up actions ask for a fresh password or email code instead;
  # on, every user (staff, client and employee logins alike) needs one, and
  # step-up asks for it again. Turning it on needs no code change
  # (docs/rollout/MFA_ROLLOUT_RUNBOOK.md).
  def self.enabled?(env: ENV)
    TRUTHY_VALUES.include?(env.fetch("REQUIRE_MFA", "false").to_s.strip.downcase)
  end

  def self.required_for?(user:, env: ENV)
    enabled?(env: env) && user.present?
  end

  # The Clerk reverification level a step-up action asks for.
  def self.step_up_level(env: ENV)
    enabled?(env: env) ? "second_factor" : "first_factor"
  end

  # The one step-up check (employee app switch, early access, view-as and the
  # employee portal's protected changes). With MFA on, a second factor
  # verified within the window; with it off, a first factor (password or
  # email code) re-verified through Clerk within the window.
  def self.recently_step_up_verified?(payload, env: ENV, max_age_minutes: STEP_UP_MAX_AGE_MINUTES, now: Time.current)
    if enabled?(env: env)
      recently_verified_second_factor?(payload, max_age_minutes: max_age_minutes, now: now)
    else
      recently_verified_first_factor?(payload, max_age_minutes: max_age_minutes, now: now)
    end
  end

  def self.verified_second_factor?(payload)
    second_factor_enrolled?(payload) && (factor_ages(payload)&.last || -1) >= 0
  end

  def self.second_factor_enrolled?(payload)
    payload.is_a?(Hash) && payload[ENROLLMENT_CLAIM] == true
  end

  # The 403 body when a session lacks the second factor MFA requires: set one
  # up first (not enrolled), or sign in again and finish it (enrolled).
  def self.denial_body(payload)
    if second_factor_enrolled?(payload)
      { error: ERROR_MESSAGE, code: ERROR_CODE }
    else
      { error: ENROLLMENT_REQUIRED_MESSAGE, code: ENROLLMENT_REQUIRED_CODE }
    end
  end

  def self.recently_verified_second_factor?(payload, max_age_minutes: STEP_UP_MAX_AGE_MINUTES, now: Time.current)
    verified_second_factor?(payload) && fresh_factor?(payload, 1, max_age_minutes, now)
  end

  # fva[0]: minutes since the first factor (password, email code) was last
  # verified, which Clerk's first_factor reverification resets.
  def self.recently_verified_first_factor?(payload, max_age_minutes: STEP_UP_MAX_AGE_MINUTES, now: Time.current)
    fresh_factor?(payload, 0, max_age_minutes, now)
  end

  # How old a factor is now, in whole minutes rounded up, or nil when the
  # token can't say. fva is the age when Clerk issued the token (iat), so the
  # time since iat is added on top. Clerk floors fva to whole minutes, so a
  # factor with age n is really under n + 1 minutes old.
  def self.factor_age_minutes(payload, index, now: Time.current)
    fva = factor_ages(payload)&.fetch(index)
    return nil if fva.nil? || fva.negative?

    elapsed = token_age_seconds(payload, now)
    elapsed && fva + (elapsed / 60.0).ceil
  end

  # Accepts only an age strictly under the window, like Clerk's own
  # afterMinutes check (afterMinutes > age), so with the rounding above the
  # verification is always less than max_age_minutes old.
  def self.fresh_factor?(payload, index, max_age_minutes, now)
    return false unless max_age_minutes.is_a?(Integer) && max_age_minutes.positive?

    age = factor_age_minutes(payload, index, now: now)
    !age.nil? && age < max_age_minutes
  end
  private_class_method :fresh_factor?

  # A missing, non-integer or future iat can't date the verification.
  def self.token_age_seconds(payload, now)
    iat = payload["iat"]
    return nil unless iat.is_a?(Integer)

    elapsed = now.to_i - iat
    elapsed unless elapsed.negative?
  end
  private_class_method :token_age_seconds

  def self.factor_ages(payload)
    ages = payload["fva"] if payload.is_a?(Hash)
    ages if ages.is_a?(Array) && ages.length == 2 && ages.all? { |age| age.is_a?(Integer) && age >= -1 }
  end
  private_class_method :factor_ages

  def self.record_denial!(user:, source:, subject_name:, request_id: nil, ip_address: nil, user_agent: nil)
    # Denial is an organization security event with no tenant context.
    TenantScope.as_system(reason: "Record organization MFA denial") do
      AuditLog.record!(
        user: user,
        organization_id: user.organization_id,
        company_id: nil,
        action: "authentication#mfa_required_denied",
        record_type: "users",
        record_id: user.id,
        event_category: "security",
        metadata: { source: source },
        request_id: request_id,
        subject_name: subject_name,
        ip_address: ip_address,
        user_agent: user_agent
      )
    end
  rescue ActiveRecord::ActiveRecordError
    Rails.logger.warn("[MFA] Could not audit authentication#mfa_required_denied for user=#{user.id} source=#{source}")
  end
end
