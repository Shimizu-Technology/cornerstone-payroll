# frozen_string_literal: true

class ApplicationController < ActionController::API
  E2E_USER_EMAIL_HEADER = "X-E2E-User-Email"

  include ClerkAuthenticatable

  around_action :reset_current_context, prepend: true
  before_action :set_current_context
  before_action :track_authenticated_user_activity

  private

  def reset_current_context
    yield
  ensure
    Current.reset
  end

  def set_current_context
    authenticated_user = current_user
    Current.user = authenticated_user if authenticated_user.is_a?(User)
    Current.organization_id = authenticated_user.organization_id if authenticated_user.is_a?(User)
    Current.company_id = current_company_id if authenticated_user.is_a?(User)
    Current.request_id = request.request_id
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
  end

  def track_authenticated_user_activity
    return unless current_user.is_a?(User)

    session_id = @clerk_token_payload&.fetch("sid", nil)
    return unless current_user.authenticated_activity_write_due?(session_id: session_id)

    current_user.with_lock do
      new_session = current_user.record_authenticated_activity!(
        session_id: session_id
      )
      next unless new_session

      # Keep the session marker and its durable sign-in evidence atomic. If
      # the audit insert fails, the digest rolls back so the next request can
      # retry instead of silently losing this session's sign-in event.
      AuditLog.record!(
        user: current_user,
        organization_id: current_user.organization_id,
        company_id: nil,
        action: "authentication#signed_in",
        record_type: "users",
        record_id: current_user.id,
        subject_name: current_user.name,
        metadata: { source: "clerk_session" },
        event_category: "security"
      )
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[UserActivity] Failed to record activity for user=#{current_user&.id}: #{e.message}")
  end

  def auth_disabled?
    return false if Rails.env.production?

    ENV["AUTH_ENABLED"] != "true"
  end

  # Fallback user for development when auth is disabled
  def current_user
    return super unless auth_disabled?

    @current_user ||= begin
      if e2e_test_identity_requested?
        candidate = User.includes(:organization)
                        .find_by(email: request.headers[E2E_USER_EMAIL_HEADER].to_s.downcase)
        candidate if candidate&.payroll_access_allowed?
      else
        preferred = User.includes(:organization).where(role: %w[super_admin admin org_admin]).find(&:payroll_access_allowed?)
        preferred || User.includes(:organization).find(&:payroll_access_allowed?)
      end
    end
  end

  def e2e_test_identity_requested?
    Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" && request.headers[E2E_USER_EMAIL_HEADER].present?
  end

  def current_organization
    current_user&.organization
  end

  def current_organization_id
    current_user&.organization_id
  end

  def current_company
    @current_company ||= Company.find_by(id: current_company_id)
  end

  def current_company_id
    @current_company_id ||= resolve_company_id
  end

  def current_user_id
    current_user&.id
  end

  def require_admin!
    require_capability!(:manage_organization, error: "Admin access required")
  end

  def require_super_admin!
    require_capability!(:manage_platform, error: "Super admin access required")
  end

  def require_manager_or_admin!
    require_capability!(:manage_client_configuration, error: "Manager or admin access required")
  end

  # Backward-compatible alias used by admin base controller.
  def require_admin_or_manager!
    require_manager_or_admin!
  end

  def require_capability!(capability, error: nil)
    return if StaffRolePolicy.allowed?(current_user, capability)

    render json: {
      error: error || StaffRolePolicy.error_message(capability)
    }, status: :forbidden
  end

  # Resolve the active company for this request.
  # Priority: X-Company-Id header (if user can access it) → user's home company → first accessible company.
  def resolve_company_id
    return current_user&.company_id unless current_user

    header_company_id = request.headers["X-Company-Id"].presence&.to_i

    if header_company_id && current_user.can_access_company?(header_company_id)
      return header_company_id
    end

    # Fall back to home company if accessible, otherwise first assigned company
    home = current_user.company_id
    if current_user.can_access_company?(home)
      home
    else
      current_user.accessible_company_ids.first || home
    end
  end
end
