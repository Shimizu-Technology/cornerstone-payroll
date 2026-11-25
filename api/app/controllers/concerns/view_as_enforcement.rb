# frozen_string_literal: true

module ViewAsEnforcement
  extend ActiveSupport::Concern

  SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

  included do
    before_action :apply_view_as_grant
    around_action :prevent_view_as_writes
    rescue_from ActiveRecord::ReadOnlyError, with: :view_as_side_effect_unavailable
  end

  private

  def view_as_requested?
    request.headers[ViewAsGrant::HEADER] != nil
  end

  def apply_view_as_grant
    Current.real_user = current_user
    return unless view_as_requested?

    response.headers["Cache-Control"] = "private, no-store"
    return deny_view_as_write unless SAFE_METHODS.include?(request.request_method) || ending_view_as?
    return view_as_unavailable unless @clerk_token_payload && !@clerk_token_payload.key?("act")

    grant = ViewAsGrant.find_for_token(request.headers[ViewAsGrant::HEADER].to_s, Current.real_user)
    return view_as_unavailable unless grant && view_as_origin_allowed?(grant)
    return view_as_unavailable unless view_as_company_header_allowed?(grant)

    if ending_view_as?
      Current.view_as_grant = grant
      return
    end

    return view_as_unavailable unless grant.open? && ViewAsGrant.allowed_staff?(Current.real_user) &&
      ViewAsGrant.allowed_company?(Current.real_user, grant.company) && view_as_surface_allowed?(grant)

    target_user = TenantScope.with_company(grant.company_id) do
      if grant.employee_view?
        @view_as_employee_context = grant.employee_context
        return view_as_unavailable unless @view_as_employee_context

        @view_as_employee_context.user
      else
        client = grant.client_target
        return view_as_unavailable unless client

        client
      end
    end
    @view_as_real_user = Current.real_user
    @applied_view_as_grant = Current.view_as_grant = grant
    @current_user = target_user
    Current.company_id = @current_company_id = grant.company_id
    Current.organization_id = grant.company.organization_id
    Current.user = @current_user
    Current.actor = AuditActor.for_user(Current.real_user)
  end

  def view_as_control?
    controller_path == "api/v1/view_as_grants"
  end

  def ending_view_as?
    view_as_control? && action_name == "destroy"
  end

  def view_as_origin_allowed?(grant)
    azp = @clerk_token_payload&.fetch("azp", nil)
    if grant.employee_view?
      TenantSubdomainRegistry.enabled_origin_company_id(azp) == grant.company_id
    else
      !TenantSubdomainRegistry.client_origin?(azp)
    end
  end

  def view_as_company_header_allowed?(grant)
    company_header = request.headers["X-Company-Id"]
    organization_header = request.headers["X-Organization-Id"]
    (company_header.nil? || company_header == grant.company_id.to_s) &&
      (organization_header.nil? || organization_header == grant.company.organization_id.to_s)
  end

  def view_as_surface_allowed?(grant)
    return true if view_as_control? && action_name == "show"
    if grant.employee_view?
      return is_a?(Api::V1::EmployeePortal::BaseController) &&
        !is_a?(Api::V1::EmployeePortal::AccountController)
    end

    controller_path.start_with?("api/v1/client/") ||
      (controller_path == "api/v1/auth" && action_name == "me") ||
      (controller_path == "api/v1/companies" && action_name == "index")
  end

  def prevent_view_as_writes
    if Current.view_as_grant && !ending_view_as?
      ActiveRecord::Base.while_preventing_writes { yield }
    else
      yield
    end
  end

  def view_as_unavailable
    render json: { error: "This support view is unavailable or has ended.", code: "view_as_unavailable" }, status: :not_found
  end

  def view_as_side_effect_unavailable(error)
    raise error unless @applied_view_as_grant

    render json: { error: "This action is unavailable while viewing as another user.", code: "view_as_read_only" },
      status: :unprocessable_content
  end

  def deny_view_as_write
    render json: { error: "This support session is view only.", code: "view_as_read_only" }, status: :forbidden
  end
end
