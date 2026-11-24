# frozen_string_literal: true

module RecentVerification
  extend ActiveSupport::Concern

  private

  def require_recent_verification!
    return head :unauthorized unless @current_user

    if @current_user.portal_employee? && !MfaPolicy.second_factor_enrolled?(@clerk_token_payload)
      return if MfaPolicy.recently_verified_any_factor?(@clerk_token_payload)
      level = "first_factor"
    else
      return if MfaPolicy.recently_verified_second_factor?(@clerk_token_payload)
      level = "second_factor"
    end

    render json: {
      clerk_error: {
        type: "forbidden",
        reason: "reverification-error",
        metadata: { reverification: { level: level, afterMinutes: MfaPolicy::STEP_UP_MAX_AGE_MINUTES } }
      }
    }, status: :forbidden
  end
end
