# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollStandingChangesController < BaseController
        def index
          render json: payload
        end

        def update
          current_company.with_lock do
            revalidate_current_company_write_access!(capability: :manage_client_configuration)
            item = PayrollStandingChange.where(company: current_company).find(params[:id])
            item.update!(change_params)
          end
          render json: payload
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Default not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(". ") }, status: :unprocessable_entity
        end

        def create
          current_company.with_lock do
            revalidate_current_company_write_access!(capability: :manage_client_configuration)
            PayrollStandingChange.create!(change_params.merge(company: current_company))
          end
          render json: payload, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(". ") }, status: :unprocessable_entity
        end

        private

        def change_params
          params.require(:standing_change).permit(:kind, :employee_id, :employee_wage_rate_id, :position, :active)
        end

        def payload
          { defaults: PayrollStandingChange.where(company: current_company).ordered.map { |item| item.as_json(only: %i[id kind employee_id employee_wage_rate_id position active]).merge(availability_error: item.availability_error) },
            employees: Employee.where(company: current_company).order(:last_name, :first_name).includes(:employee_wage_rates).map do |employee|
              { id: employee.id, name: employee.full_name, status: employee.status, variable_salary: employee.variable_salary?,
                hourly: employee.hourly_pay_basis?, wage_rates: employee.active_wage_rates.map { |rate| { id: rate.id, label: rate.label, rate: rate.rate } } }
            end }
        end
      end
    end
  end
end
