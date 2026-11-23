# frozen_string_literal: true

class ApplicationController < ActionController::API
  rescue_from StagingOutboundPolicy::Blocked do |error|
    render json: { error: error.message, staging: true }, status: :service_unavailable
  end
  E2E_USER_EMAIL_HEADER = "X-E2E-User-Email"

  include ClerkAuthenticatable
  include PdfGenerationFailureHandling

  around_action :reset_current_context, prepend: true
  before_action :require_explicit_company_access, if: -> { is_a?(ExplicitCompanyAccess) }
  before_action :set_current_context
  before_action :track_authenticated_user_activity

  private

  def render_write_maintenance(message = nil)
    response.headers["Retry-After"] = WriteMaintenance::RETRY_AFTER.to_s
    response.headers["Cache-Control"] = "no-store"
    render json: WriteMaintenance.payload(message), status: :service_unavailable
  end

  def reset_current_context
    yield
  ensure
    Current.reset
  end

  def set_current_context
    authenticated_user = current_user
    if authenticated_user.is_a?(User)
      Current.user = authenticated_user
      Current.actor = AuditActor.for_user(authenticated_user)
      Current.organization_id = current_organization_id
      Current.company_id = current_company_id
    end
    Current.request_id = request.request_id
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
  end

  def track_authenticated_user_activity
    return unless current_user.is_a?(User)

    session_id = @clerk_token_payload&.fetch("sid", nil)
    return unless current_user.authenticated_activity_write_due?(session_id: session_id)

    TenantScope.as_system(reason: "Record authenticated organization session") do
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
    return current_user&.organization unless finance_request?

    requested_id = request.headers["X-Organization-Id"].presence
    if requested_id
      organization = Organization.find_by(id: requested_id.to_s.to_i) if requested_id.to_s.match?(/\A[1-9]\d*\z/)
      return organization if organization && (current_user&.super_admin? || organization.id == current_user&.organization_id)

      return nil
    end

    current_user&.super_admin? ? current_company&.organization || current_user.organization : current_user&.organization
  end

  def finance_request?
    controller_path.start_with?("api/v1/admin/invoice", "api/v1/admin/expense", "api/v1/admin/finance_")
  end

  def current_organization_id
    current_organization&.id
  end

  def current_company
    @current_company ||= Company.find_by(id: current_company_id)
  end

  def current_company_id
    @current_company_id ||= resolve_company_id
  end

  def forbid_migration_rehearsal_official_action!
    return unless current_company&.test_workspace?

    render json: {
      error: "This action is unavailable in a test workspace. Test workspaces cannot issue checks, move money, commit payroll, or produce filing-ready records."
    }, status: :forbidden
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

  def authorized_explicit_company_id(value)
    return unless value.match?(/\A[1-9]\d{0,18}\z/)

    id = value.to_i
    return if id > 2**63 - 1

    id if Company.active.exists?(id) && current_user.can_access_company?(id)
  end

  # Resolve the active company for this request.
  # Explicit scope never falls back. Company discovery can still suggest an
  # accessible selection when the caller has a stale header, without reading or
  # writing another client's business records.
  def resolve_company_id
    return current_user&.company_id unless current_user

    return if current_user.employee? || current_user.portal_employee?

    requested_company = request.headers["X-Company-Id"]
    return authorized_explicit_company_id(requested_company) unless requested_company.nil?

    # Fall back to home company if accessible, otherwise first assigned company
    home = current_user.company_id
    if current_user.can_access_company?(home)
      home
    else
      current_user.accessible_company_ids.first || home
    end
  end
end
