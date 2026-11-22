# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollStandingChangesController < BaseController
        def rule
          current_company.with_lock do
            revalidate_current_company_write_access!(capability: :manage_client_configuration)
            current_company.update!(params.permit(:regular_pay_lookback, :regular_pay_threshold).to_h)
            AuditLog.record!(company_id: current_company.id, action: "payroll_standing_changes#rule",
              record_type: "Company", record_id: current_company.id, metadata: { changes: current_company.saved_changes })
          end
          render json: payload
        rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid
          render json: { error: "Choose a threshold from 1 to the lookback, and a lookback up to 24 runs" }, status: :unprocessable_entity
        end

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
          params.require(:standing_change).permit(:kind, :employee_id, :employee_wage_rate_id, :position, :active, :label, :help_text, :required, :allow_none)
        end

        def payload
          { regular_pay_rule: { lookback: current_company.regular_pay_lookback, threshold: current_company.regular_pay_threshold }, defaults: PayrollStandingChange.where(company: current_company).ordered.map { |item| item.as_json(only: %i[id kind employee_id employee_wage_rate_id position active label help_text required allow_none]).merge(availability_error: item.availability_error) },
            employees: Employee.where(company: current_company).order(:last_name, :first_name).preload(:employee_wage_rates, :employee_wage_rate_versions, :employee_compensation_changes).map do |employee|
              # Settings show today's rates; each payroll resolves its own period end date.
              { id: employee.id, name: employee.full_name, status: employee.status, variable_salary: employee.variable_salary?,
                hourly: employee.hourly_pay_basis?, wage_rates: employee.wage_rates_on(PayrollBusinessClock.today).map { |rate| { id: rate.id, label: rate.label, rate: rate.rate } } }
            end }
        end
      end
    end
  end
end
