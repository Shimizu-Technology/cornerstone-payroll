# frozen_string_literal: true

module StaffEmployeeLifecycleAccess
  extend ActiveSupport::Concern

  included do
    before_action :require_client_managed_lifecycle!
  end

  private

  def require_client_managed_lifecycle!
    return if current_company && CompanyFeatures.for(current_company).client_managed_employee_lifecycle?

    render json: {
      error: "Client-managed employee lifecycle is not enabled for this company.",
      code: "client_lifecycle_disabled"
    }, status: :forbidden
  end
end
