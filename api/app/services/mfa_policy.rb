# frozen_string_literal: true

class MfaPolicy
  class VerificationRequired < StandardError; end

  ERROR_MESSAGE = "Multi-factor authentication is required before accessing payroll."
  ERROR_CODE = "mfa_required"
  TRUTHY_VALUES = %w[1 true t yes y on].freeze

  def self.enabled?(env: ENV)
    TRUTHY_VALUES.include?(env.fetch("REQUIRE_MFA", "false").to_s.strip.downcase)
  end

  def self.required_for?(user:, env: ENV)
    enabled?(env: env) && user.present? && !user.employee? && !user.portal_employee?
  end

  def self.verified_second_factor?(payload)
    return false unless payload.is_a?(Hash)

    ages = payload["fva"]
    return false unless ages.is_a?(Array) && ages.length == 2

    first, second = ages
    first.is_a?(Integer) && first >= -1 && second.is_a?(Integer) && second >= 0
  end

  def self.recently_verified?(payload, max_age_minutes: 10)
    return false unless max_age_minutes.is_a?(Integer) && max_age_minutes >= 0

    verified_second_factor?(payload) && payload["fva"][1] <= max_age_minutes
  end

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
