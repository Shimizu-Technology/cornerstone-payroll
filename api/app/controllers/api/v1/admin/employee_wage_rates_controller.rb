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

          rate = EmployeeWageRate.new(rate_params)
          rate.employee = employee
          if rate.save
            render json: { wage_rate: rate_payload(rate) }, status: :created
          else
            render json: { errors: rate.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/admin/employee_wage_rates/:id
        def update
          rate = scoped_rate(params[:id])
          unless rate
            return render json: { error: "Wage rate not found" }, status: :not_found
          end

          if rate.update(rate_update_params)
            render json: { wage_rate: rate_payload(rate) }
          else
            render json: { errors: rate.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/admin/employee_wage_rates/:id
        def destroy
          rate = scoped_rate(params[:id])
          unless rate
            return render json: { error: "Wage rate not found" }, status: :not_found
          end

          rate.destroy!
          render json: { message: "Wage rate deleted" }
        end

        private

        def rate_params
          params.require(:employee_wage_rate).permit(:employee_id, :label, :rate, :is_primary, :active)
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
