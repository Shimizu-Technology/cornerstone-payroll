# frozen_string_literal: true

module ExplicitCompanyAccess
  extend ActiveSupport::Concern

  private

  def require_explicit_company_access
    return if Current.view_as_grant

    requested_company = request.headers["X-Company-Id"]
    return if requested_company.nil?
    return unless current_user
    # ApplicationController invokes this after Clerk and MFA, before Current
    # or the action scope can resolve a company. Keep the authorized selection.
    @current_company_id = authorized_explicit_company_id(requested_company)
    return if @current_company_id

    render json: {
      error: "This client workspace is unavailable or your access has expired. Your changes were not saved. Select the intended client after your access is restored.",
      code: "company_context_unavailable"
    }, status: :forbidden
  end

  def enforce_company_access!
    return if current_user.nil? || current_user.can_access_company?(current_company_id)

    render json: { error: "You do not have access to this company" }, status: :forbidden
  end
end
