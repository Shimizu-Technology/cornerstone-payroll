# frozen_string_literal: true

class MfaPolicy
  class VerificationRequired < StandardError; end

  ERROR_MESSAGE = "Multi-factor authentication is required before accessing payroll."
  ERROR_CODE = "mfa_required"
  ENROLLMENT_REQUIRED_CODE = "mfa_enrollment_required"
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
  def self.recently_step_up_verified?(payload, env: ENV, max_age_minutes: STEP_UP_MAX_AGE_MINUTES)
    if enabled?(env: env)
      recently_verified_second_factor?(payload, max_age_minutes: max_age_minutes)
    else
      recently_verified_first_factor?(payload, max_age_minutes: max_age_minutes)
    end
  end

  def self.verified_second_factor?(payload)
    second_factor_enrolled?(payload) && (factor_ages(payload)&.last || -1) >= 0
  end

  def self.second_factor_enrolled?(payload)
    payload.is_a?(Hash) && payload[ENROLLMENT_CLAIM] == true
  end

  # fva counts whole minutes, so an inclusive limit accepts a verification up to
  # about a minute older than Clerk's own afterMinutes check. That only makes the
  # server slightly more lenient than the prompt; it never asks for a factor twice.
  def self.recently_verified_second_factor?(payload, max_age_minutes: STEP_UP_MAX_AGE_MINUTES)
    return false unless valid_window?(max_age_minutes)

    verified_second_factor?(payload) && payload["fva"][1] <= max_age_minutes
  end

  # fva[0]: minutes since the first factor (password, email code) was last
  # verified, which Clerk's first_factor reverification resets.
  def self.recently_verified_first_factor?(payload, max_age_minutes: STEP_UP_MAX_AGE_MINUTES)
    return false unless valid_window?(max_age_minutes)

    age = factor_ages(payload)&.first || -1
    age.between?(0, max_age_minutes)
  end

  def self.valid_window?(max_age_minutes)
    max_age_minutes.is_a?(Integer) && max_age_minutes >= 0
  end
  private_class_method :valid_window?

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
