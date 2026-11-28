# frozen_string_literal: true

module StaffEmployeeLifecycleAccess
  extend ActiveSupport::Concern

  included do
    before_action :require_staff_employee_lifecycle!
  end

  private

  def require_staff_employee_lifecycle!
    return if staff_employee_lifecycle_available?(current_company)

    render json: {
      error: "Client-managed employee lifecycle is not enabled for this company.",
      code: "client_lifecycle_disabled"
    }, status: :forbidden
  end

  def staff_employee_lifecycle_available?(company)
    StaffEmployeeLifecycle.available?(company, client_managed_only: action_name == "return_to_client")
  end
end
