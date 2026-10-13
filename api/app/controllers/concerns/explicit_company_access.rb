# frozen_string_literal: true

module ExplicitCompanyAccess
  extend ActiveSupport::Concern

  included do
    before_action :require_explicit_company_access
  end

  private

  def require_explicit_company_access
    requested_company = request.headers["X-Company-Id"].presence
    return unless requested_company
    return if requested_company.match?(/\A[1-9]\d*\z/) && current_user&.can_access_company?(requested_company.to_i)

    render json: { error: "You do not have access to this company" }, status: :forbidden
  end
end
