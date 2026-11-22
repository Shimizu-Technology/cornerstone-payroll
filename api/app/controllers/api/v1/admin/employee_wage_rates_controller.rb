# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeWageRatesController < BaseController
        # GET /api/v1/admin/employee_wage_rates?employee_id=X
        def index
          unless params[:employee_id].present?
            return render json: { error: "employee_id is required" }, status: :unprocessable_entity
          end

          employee = scoped_employee(params[:employee_id])
          unless employee
            return render json: { error: "Employee not found" }, status: :not_found
          end

          rates = employee.employee_wage_rates.order(:label)
          render json: { wage_rates: rates.map { |r| rate_payload(r) } }
        end

        # POST /api/v1/admin/employee_wage_rates
        def create
          employee = scoped_employee(rate_params[:employee_id])
          unless employee
            return render json: { error: "Employee not found" }, status: :not_found
          end

          label = rate_params[:label].to_s.strip
          result = change_wage_rates!(employee, rate_params.except(:employee_id).to_h.merge(label: label))
          rate = employee.employee_wage_rates.reload.find_by!(label: label)
          render json: { wage_rate: rate_payload(rate), compensation_warnings: result.warnings }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue EmployeeCompensationChangeService::Error => e
          render_compensation_error(e)
        end

        # PATCH /api/v1/admin/employee_wage_rates/:id
        def update
          rate = scoped_rate(params[:id])
          unless rate
            return render json: { error: "Wage rate not found" }, status: :not_found
          end

          result = change_wage_rates!(rate.employee, rate_update_params.to_h.merge(id: rate.id))
          render json: { wage_rate: rate_payload(rate.reload), compensation_warnings: result.warnings }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue EmployeeCompensationChangeService::Error => e
          render_compensation_error(e)
        end

        # DELETE /api/v1/admin/employee_wage_rates/:id
        # Ends the rate on the effective date; its history and the payroll
        # buckets that used it are kept.
        def destroy
          rate = scoped_rate(params[:id])
          unless rate
            return render json: { error: "Wage rate not found" }, status: :not_found
          end

          result = change_wage_rates!(rate.employee, { id: rate.id, remove: true })
          render json: { message: "Wage rate ended", compensation_warnings: result.warnings }
        rescue EmployeeCompensationChangeService::Error => e
          render_compensation_error(e)
        end

        private

        def rate_params
          params.require(:employee_wage_rate).permit(:employee_id, :label, :rate, :is_primary, :active)
        end

        def compensation_params
          params.fetch(:employee_wage_rate, {}).permit(:effective_on, :reason, :historical_correction)
        end

        def change_wage_rates!(employee, edit)
          EmployeeCompensationChangeService.new(
            employee: employee,
            actor: current_user,
            source: "staff",
            reason: compensation_params[:reason],
            effective_on: compensation_params[:effective_on],
            historical_correction: compensation_params[:historical_correction],
            wage_rate_edits: [ edit.symbolize_keys ]
          ).call!
        end

        def render_compensation_error(error)
          code = error.is_a?(EmployeeCompensationChangeService::LockedPeriodError) ? "compensation_locked_period" : "compensation_change_invalid"
          render json: { error: error.message, code: code, errors: [ error.message ] }, status: :unprocessable_entity
        end

        def rate_update_params
          params.require(:employee_wage_rate).permit(:label, :rate, :is_primary, :active)
        end

        def rate_payload(rate)
          {
            id: rate.id,
            employee_id: rate.employee_id,
            label: rate.label,
            rate: rate.rate,
            is_primary: rate.is_primary,
            active: rate.active,
            created_at: rate.created_at,
            updated_at: rate.updated_at
          }
        end

        def scoped_employee(id)
          Employee.find_by(id: id, company_id: current_company_id)
        end

        def scoped_rate(id)
          EmployeeWageRate.joins(:employee).find_by(id: id, employees: { company_id: current_company_id })
        end
      end
    end
  end
end
