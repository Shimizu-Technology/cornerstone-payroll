# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeePayrollFieldsController < BaseController
        before_action :set_employee
        before_action :set_assignment, only: [ :update, :destroy ]

        def index
          assignments = @employee.employee_payroll_fields.active.includes(:payroll_field_definition).order("payroll_field_definitions.sort_order ASC", "payroll_field_definitions.name ASC")
          render json: { employee_payroll_fields: assignments.map { |assignment| assignment_json(assignment) } }
        end

        def create
          attrs = assignment_params
          assignment = upsert_assignment(attrs)
          status = assignment.previously_new_record? ? :created : :ok
          render json: { employee_payroll_field: assignment_json(assignment) }, status: status
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end

        def update
          if @assignment.update(assignment_params)
            render json: { employee_payroll_field: assignment_json(@assignment) }
          else
            render json: { errors: @assignment.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def bulk_update
          raw_assignments = Array(params.require(:employee_payroll_fields))
          permitted_assignments = raw_assignments.map { |raw| assignment_params_from(raw) }
          active_definition_ids = permitted_assignments
            .select { |attrs| attrs[:active] != false && attrs[:payroll_field_definition_id].present? }
            .map { |attrs| attrs[:payroll_field_definition_id] }

          if active_definition_ids.uniq.length != active_definition_ids.length
            return render json: { errors: ["Payroll field assignments cannot contain duplicate active fields"] }, status: :unprocessable_entity
          end

          assignments = []
          EmployeePayrollField.transaction do
            permitted_assignments.each do |attrs|
              assignment = if attrs[:id].present?
                @employee.employee_payroll_fields.find(attrs.delete(:id))
              else
                next if attrs[:active] == false

                @employee.employee_payroll_fields.find_or_initialize_by(payroll_field_definition_id: attrs[:payroll_field_definition_id])
              end

              assignment.assign_attributes(attrs.merge(active: attrs.key?(:active) ? attrs[:active] : true))
              assignment.save!
              assignments << assignment
            end
          end

          render json: { employee_payroll_fields: assignments.map { |assignment| assignment_json(assignment) } }
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound, ActionController::ParameterMissing => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end

        def destroy
          @assignment.update!(active: false)
          render json: { employee_payroll_field: assignment_json(@assignment) }
        end

        private

        def set_employee
          @employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          return if @employee

          render json: { error: "Employee not found" }, status: :not_found
        end

        def set_assignment
          @assignment = @employee.employee_payroll_fields.find(params[:id])
        end

        def upsert_assignment(attrs)
          assignment = @employee.employee_payroll_fields.find_or_initialize_by(payroll_field_definition_id: attrs[:payroll_field_definition_id])
          assignment.assign_attributes(attrs.merge(active: attrs.key?(:active) ? attrs[:active] : true))
          assignment.save!
          assignment
        rescue ActiveRecord::RecordNotUnique
          assignment = @employee.employee_payroll_fields.find_by!(payroll_field_definition_id: attrs[:payroll_field_definition_id])
          assignment.assign_attributes(attrs.merge(active: attrs.key?(:active) ? attrs[:active] : true))
          assignment.save!
          assignment
        end

        def assignment_params
          assignment_params_from(params.require(:employee_payroll_field))
        end

        def assignment_params_from(raw_params)
          raw_hash = raw_params.respond_to?(:to_unsafe_h) ? raw_params.to_unsafe_h : raw_params.to_h
          permitted = ActionController::Parameters.new(raw_hash).permit(
            :id, :payroll_field_definition_id, :amount, :percentage, :active,
            :start_date, :end_date, :notes, :employee_loan_id
          )

          if permitted[:payroll_field_definition_id].present?
            field = PayrollFieldDefinition.find_by(id: permitted[:payroll_field_definition_id], company_id: current_company_id)
            permitted[:payroll_field_definition_id] = field&.id
          end

          if permitted[:employee_loan_id].present?
            loan = EmployeeLoan.find_by(id: permitted[:employee_loan_id], company_id: current_company_id, employee_id: @employee.id)
            permitted[:employee_loan_id] = loan&.id
          end

          permitted
        end

        def assignment_json(assignment)
          field = assignment.payroll_field_definition
          {
            id: assignment.id,
            employee_id: assignment.employee_id,
            payroll_field_definition_id: assignment.payroll_field_definition_id,
            amount: assignment.amount&.to_f,
            percentage: assignment.percentage&.to_f,
            active: assignment.active,
            start_date: assignment.start_date,
            end_date: assignment.end_date,
            notes: assignment.notes,
            employee_loan_id: assignment.employee_loan_id,
            payroll_field: field && {
              id: field.id,
              name: field.name,
              kind: field.kind,
              tax_treatment: field.tax_treatment,
              category: field.category,
              amount_type: field.amount_type,
              default_amount: field.default_amount&.to_f,
              default_percentage: field.default_percentage&.to_f,
              show_in_payroll_grid: field.show_in_payroll_grid,
              active: field.active
            }
          }
        end
      end
    end
  end
end
