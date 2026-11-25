# frozen_string_literal: true

module MfaEnforceable
  extend ActiveSupport::Concern

  included do
    rescue_from MfaPolicy::VerificationRequired, with: :render_mfa_required
  end

  private

  def enforce_mfa!
    deny_mfa!(@current_user) if mfa_verification_required_for?(@current_user)
  end

  def mfa_verification_required_for?(user)
    MfaPolicy.required_for?(user: user) && !MfaPolicy.verified_second_factor?(@clerk_token_payload)
  end

  def deny_mfa!(user)
    MfaPolicy.record_denial!(
      user: user, source: "clerk_session", subject_name: user.name,
      request_id: request.request_id, ip_address: request.remote_ip, user_agent: request.user_agent
    )
    render_mfa_required
  end

  # One denial for every surface (staff, client and employee APIs, invitation
  # binding, cable tickets), split by what the person has to do next. A login
  # with no second factor yet gets mfa_enrollment_required, so the apps send it
  # to set one up; an enrolled login whose session skipped the second step gets
  # mfa_required, so it signs in again and finishes it.
  def render_mfa_required
    render json: MfaPolicy.denial_body(@clerk_token_payload), status: :forbidden
  end
end
