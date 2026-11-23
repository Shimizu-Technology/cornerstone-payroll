# frozen_string_literal: true

module MfaEnforceable
  extend ActiveSupport::Concern

  included do
    rescue_from MfaPolicy::VerificationRequired, with: :render_mfa_required
  end

  private

  def enforce_mfa!
    return unless MfaPolicy.required_for?(user: @current_user)
    return if MfaPolicy.verified_second_factor?(@clerk_token_payload)

    MfaPolicy.record_denial!(user: @current_user, source: "clerk_session", request_id: request.request_id)
    render_mfa_required
  end

  def render_mfa_required
    render json: { error: MfaPolicy::ERROR_MESSAGE, code: MfaPolicy::ERROR_CODE }, status: :forbidden
  end
end
