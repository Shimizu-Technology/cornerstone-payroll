# frozen_string_literal: true

module RecentVerification
  extend ActiveSupport::Concern

  private

  def require_recent_verification!
    return head :unauthorized unless @current_user

    enrolled = MfaPolicy.second_factor_enrolled?(@clerk_token_payload)
    if MfaPolicy.employee_only?(@current_user) && !enrolled
      return if MfaPolicy.recently_verified_any_factor?(@clerk_token_payload)
      level = "first_factor"
    else
      return if MfaPolicy.recently_verified_second_factor?(@clerk_token_payload)
      # Clerk would accept a fresh password for an unenrolled user and retry,
      # and this check would refuse it again. Send them to enrollment instead.
      return render_enrollment_required unless enrolled

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

  def render_enrollment_required
    render json: {
      error: "Set up two-step sign-in to make this change.",
      code: MfaPolicy::ENROLLMENT_REQUIRED_CODE
    }, status: :forbidden
  end
end
