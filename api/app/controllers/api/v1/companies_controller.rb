# frozen_string_literal: true

module Api
  module V1
    class CompaniesController < ApplicationController
      def index
        return render json: { error: "Not authenticated" }, status: :unauthorized unless current_user

        companies = Company.where(id: current_user.accessible_company_ids)
                           .yield_self { |scope| params[:active].present? ? scope.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) : scope }
                           .order(:name)
        company_ids = companies.pluck(:id)
        total_employee_counts = employee_counts_by_company(company_ids)
        active_employee_counts = employee_counts_by_company(company_ids, active_only: true)

        render json: {
          companies: companies.map do |company|
            company_summary(
              company,
              total_employee_counts: total_employee_counts,
              active_employee_counts: active_employee_counts
            )
          end,
          can_manage_clients: current_user.organization_admin?,
          can_switch_company: current_user.accessible_company_ids.size > 1,
          current_company_id: current_company_id
        }
      end

      private

      def company_summary(company, total_employee_counts:, active_employee_counts:)
        {
          id: company.id,
          name: company.name,
          active: company.active,
          active_employees: active_employee_counts.fetch(company.id, 0),
          total_employees: total_employee_counts.fetch(company.id, 0),
          pay_frequency: company.pay_frequency,
          historical_payroll_enabled: company.historical_payroll_enabled
        }
      end

      def employee_counts_by_company(company_ids, active_only: false)
        return {} if company_ids.empty?

        scope = Employee.where(company_id: company_ids)
        scope = scope.active if active_only
        scope.group(:company_id).count
      end
    end
  end
end
