# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeRetirementYearInputsController < BaseController
        before_action :set_employee

        def index
          inputs = @employee.employee_retirement_year_inputs.includes(:created_by).recent_first
          inputs = inputs.where(tax_year: params[:tax_year]) if params[:tax_year].present?
          render json: { data: inputs.map { |input| serialize(input) } }
        end

        def create
          input = nil
          EmployeeRetirementYearInput.transaction do
            input = @employee.employee_retirement_year_inputs.create!(
              input_params.merge(company: @employee.company, created_by: current_user)
            )
            AuditLog.record!(user: current_user, company_id: @employee.company_id,
              organization_id: @employee.company.organization_id,
              action: "employee_retirement_year_inputs#create", record_type: "EmployeeRetirementYearInput",
              record_id: input.id, subject_name: @employee.full_name,
              metadata: { reason: input.reason, after_values: input.snapshot_attributes })
          end
          render json: { data: serialize(input) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        end

        private

        def set_employee
          @employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          render json: { error: "Employee not found" }, status: :not_found unless @employee
        end

        def input_params
          params.require(:retirement_year_input).permit(*EmployeeRetirementYearInput::SNAPSHOT_ATTRIBUTES)
        end

        def serialize(input)
          input.as_json(except: [ :created_by_id ]).merge("created_by_name" => input.created_by&.name)
        end
      end
    end
  end
end
