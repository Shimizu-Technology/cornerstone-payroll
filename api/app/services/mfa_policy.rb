# frozen_string_literal: true

class MfaPolicy
  class VerificationRequired < StandardError; end

  ERROR_MESSAGE = "Multi-factor authentication is required before accessing payroll."
  ERROR_CODE = "mfa_required"
  ENROLLMENT_REQUIRED_CODE = "mfa_enrollment_required"
  STEP_UP_MAX_AGE_MINUTES = 10
  ENROLLMENT_CLAIM = "two_factor_enabled"
  TRUTHY_VALUES = %w[1 true t yes y on].freeze

  def self.enabled?(env: ENV)
    TRUTHY_VALUES.include?(env.fetch("REQUIRE_MFA", "false").to_s.strip.downcase)
  end

  def self.required_for?(user:, env: ENV)
    enabled?(env: env) && user.present? && !employee_only?(user)
  end

  def self.employee_only?(user)
    user.employee? || user.portal_employee?
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
    return false unless max_age_minutes.is_a?(Integer) && max_age_minutes >= 0

    verified_second_factor?(payload) && payload["fva"][1] <= max_age_minutes
  end

  def self.recently_verified_any_factor?(payload)
    age = factor_ages(payload)&.first || -1
    age.between?(0, STEP_UP_MAX_AGE_MINUTES)
  end

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
