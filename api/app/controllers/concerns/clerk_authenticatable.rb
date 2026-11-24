# frozen_string_literal: true

# Clerk JWT authentication concern.
# Verifies Bearer tokens using Clerk's JWKS endpoint.
# Following the pattern from Brain Dump / CLERK_AUTH_SETUP_GUIDE.md
module ClerkAuthenticatable
  extend ActiveSupport::Concern

  include MfaEnforceable

  included do
    before_action :authenticate_user!, :enforce_mfa!, unless: :auth_disabled?
  end

  private

  def authenticate_user!
    token = extract_token
    unless token
      render json: { error: "Authorization header missing" }, status: :unauthorized
      return
    end

    @clerk_token_payload = verify_clerk_token(token)
    unless @clerk_token_payload
      render json: { error: "Invalid or expired token" }, status: :unauthorized
      return
    end

    if TenantSubdomainRegistry.client_origin?(@clerk_token_payload["azp"]) && !allow_client_subdomain_token?
      return render json: { error: "This sign-in is limited to the employee portal" }, status: :forbidden
    end

    clerk_id = @clerk_token_payload["sub"]
    unless clerk_id.is_a?(String) && clerk_id.present? && !clerk_id.start_with?("pending_")
      render json: { error: "Invalid Clerk identity" }, status: :unauthorized
      return
    end
    @current_user = User.find_by(clerk_id: clerk_id)

    if StagingOutboundPolicy.staging? && !StagingOutboundPolicy.bindings.value?(clerk_id)
      render json: { error: "Staging access is restricted to named testers" }, status: :forbidden
      return
    end

    if StagingOutboundPolicy.staging? && !@current_user
      render json: { error: "Staging tester has not been explicitly bound" }, status: :forbidden
      return
    end

    if !@current_user && WriteMaintenance.enabled?
      return render_write_maintenance("New Payroll sign-ins are paused during maintenance. Try again shortly using this same sign-in.")
    end

    unless @current_user
      denied_user = nil
      @current_user = PayrollInvitation.new.bind_from_metadata(clerk_id, request: request, azp: @clerk_token_payload["azp"]) do |candidate|
        denied_user = candidate if mfa_verification_required_for?(candidate)
        !denied_user
      end
      return deny_mfa!(denied_user) if denied_user
    end
    unless @current_user
      render json: { error: "This Clerk account is not linked to Payroll. Use your invitation or contact your administrator.",
                    code: "payroll_account_unbound" }, status: :unauthorized
      return
    end

    unless StagingOutboundPolicy.tester?(user_id: @current_user.id, email: @current_user.email, id: clerk_id)
      @current_user = nil
      render json: { error: "Staging tester binding does not match" }, status: :forbidden
      return
    end

    unless @current_user.payroll_access_allowed?
      @current_user = nil
      return render json: { error: "Account inactive" }, status: :unauthorized
    end

    # An employee-only login's sessions from before it was deactivated stay
    # refused after it is reactivated (M4-2).
    if EmployeeLinks::SessionFence.fenced?(@current_user, @clerk_token_payload)
      @current_user = nil
      render json: EmployeeLinks::SessionFence::SIGN_IN_AGAIN, status: :unauthorized
    end
  end

  def allow_client_subdomain_token?
    false
  end

  def extract_token
    header = request.headers["Authorization"]
    return nil unless header&.start_with?("Bearer ")
    header.split(" ").last
  end

  def verify_clerk_token(token)
    clerk_token_verifier.verify(token)
  end

  def clerk_token_verifier
    @clerk_token_verifier ||= ClerkTokenVerifier.new
  end

  def current_user
    @current_user
  end
end
