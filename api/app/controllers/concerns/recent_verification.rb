# frozen_string_literal: true

# Step-up before a sensitive change. MfaPolicy decides what counts: a fresh
# second factor with REQUIRE_MFA on, a fresh first factor (password or email
# code, through Clerk reverification) while it's off. The 403 tells Clerk
# which level to prompt for.
module RecentVerification
  extend ActiveSupport::Concern

  private

  def impersonated_session?
    Current.view_as_grant.present? || @clerk_token_payload&.key?("act") == true
  end

  def require_direct_recent_verification!(impersonation_error: "Exit Sign in as before changing client approval.")
    if impersonated_session?
      return render json: { error: impersonation_error }, status: :forbidden
    end

    require_recent_verification!
  end

  def require_recent_verification!
    return head :unauthorized unless @current_user
    return if MfaPolicy.recently_step_up_verified?(@clerk_token_payload)

    # With MFA on, Clerk would accept a fresh password for an unenrolled user
    # and retry, and this check would refuse it again. Send them to
    # enrollment instead. With MFA off nobody needs to enroll.
    if MfaPolicy.enabled? && !MfaPolicy.second_factor_enrolled?(@clerk_token_payload)
      return render_enrollment_required
    end

    render json: {
      clerk_error: {
        type: "forbidden",
        reason: "reverification-error",
        metadata: { reverification: { level: MfaPolicy.step_up_level, afterMinutes: MfaPolicy::STEP_UP_MAX_AGE_MINUTES } }
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
