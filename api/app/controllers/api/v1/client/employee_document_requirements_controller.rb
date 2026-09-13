# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeeDocumentRequirementsController < BaseController
        before_action :set_employee

        def index
          requirements = @employee.employee_document_requirements
            .includes(:client_document)
            .order(required_for_payroll: :desc, requirement_type: :asc)
          render json: {
            data: requirements.map { |requirement| EmployeeDocumentRequirementPresenter.call(requirement, client: true) },
            readiness: EmployeeDocumentReadiness.summary(@employee)
          }
        end

        private

        def set_employee
          @employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          return if @employee

          render json: { error: "Employee not found" }, status: :not_found
        end
      end
    end
  end
end
