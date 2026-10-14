# frozen_string_literal: true

module ExplicitCompanyAccess
  extend ActiveSupport::Concern

  included do
    # Check before ApplicationController resolves Current.company_id. Explicit
    # scope is a boundary, never a hint that may fall back to another client.
    before_action :require_explicit_company_access, prepend: true
  end

  private

  def require_explicit_company_access
    requested_company = request.headers["X-Company-Id"]
    return if requested_company.nil?
    return unless current_user
    return if requested_company.match?(/\A[1-9]\d*\z/) &&
      Company.exists?(requested_company.to_i) && current_user.can_access_company?(requested_company.to_i)

    render json: {
      error: "This client workspace is unavailable or your access has expired. Your changes were not saved. Select the intended client after your access is restored.",
      code: "company_context_unavailable"
    }, status: :forbidden
  end
end
