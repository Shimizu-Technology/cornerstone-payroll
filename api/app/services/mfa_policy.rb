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
    enabled?(env: env) && user.present? && (user.staff_member? || user.client?)
  end

  def self.verified_second_factor?(payload)
    ages = payload&.fetch("fva", nil)
    ages.is_a?(Array) && ages.length == 2 && ages[1].is_a?(Integer) && ages[1] >= 0
  end

  def self.recently_verified?(payload, max_age_minutes: 10)
    verified_second_factor?(payload) && payload["fva"][1] <= max_age_minutes
  end

  def self.record_denial!(user:, source:, request_id: nil)
    AuditLog.record!(
      user: user,
      organization_id: user.organization_id,
      company_id: nil,
      action: "authentication#mfa_required_denied",
      record_type: "users",
      record_id: user.id,
      event_category: "security",
      metadata: { source: source },
      request_id: request_id
    )
  rescue ActiveRecord::ActiveRecordError
    Rails.logger.warn("[MFA] Could not audit authentication#mfa_required_denied for user=#{user.id} source=#{source}")
  end
end
