# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeDocumentRequirementsController < BaseController
        before_action :set_employee
        before_action :set_requirement, only: :update

        def index
          requirements = @employee.employee_document_requirements
            .includes(:client_document, :reviewed_by, events: [ :actor, :client_document ])
            .order(required_for_payroll: :desc, requirement_type: :asc)

          render json: payload(requirements)
        end

        def update
          EmployeeDocumentRequirementReviewService.new(
            requirement: @requirement,
            actor: current_user,
            attributes: requirement_params
          ).call!
          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: "employee_document_requirements#update",
            record_type: "employee_document_requirements",
            record_id: @requirement.id,
            metadata: {
              employee_id: @employee.id,
              requirement_type: @requirement.requirement_type,
              status: @requirement.status
            },
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )

          render json: payload(
            @employee.employee_document_requirements
              .includes(:client_document, :reviewed_by, events: [ :actor, :client_document ])
              .order(required_for_payroll: :desc, requirement_type: :asc)
          )
        rescue EmployeeDocumentRequirementReviewService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        rescue ActiveRecord::StaleObjectError
          render json: { error: "This readiness item changed. Refresh it before saving again." }, status: :conflict
        end

        private

        def set_employee
          @employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          return if @employee

          render json: { error: "Employee not found" }, status: :not_found
        end

        def set_requirement
          @requirement = @employee&.employee_document_requirements&.find_by(id: params[:id])
          return if @requirement

          render json: { error: "Document requirement not found" }, status: :not_found
        end

        def requirement_params
          params.require(:document_requirement).permit(:status, :client_document_id, :review_note, :lock_version)
        end

        def payload(requirements)
          rows = requirements.map { |requirement| EmployeeDocumentRequirementPresenter.call(requirement) }
          {
            data: rows,
            readiness: EmployeeDocumentReadiness.summary(@employee)
          }
        end
      end
    end
  end
end
