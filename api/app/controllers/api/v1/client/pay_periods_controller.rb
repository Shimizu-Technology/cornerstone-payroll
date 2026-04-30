# frozen_string_literal: true

module Api
  module V1
    module Client
      class PayPeriodsController < BaseController
        before_action :set_pay_period, only: :show

        def index
          pay_periods = PayPeriod.reportable_committed
                                 .where(company_id: current_company_id)
                                 .includes(payroll_items: :employee)
                                 .period_chronological

          pay_periods = pay_periods.for_year(params[:year].to_i) if params[:year].present?

          render json: {
            pay_periods: pay_periods.map { |pay_period| pay_period_summary(pay_period) },
            meta: {
              total: pay_periods.size,
              statuses: { "committed" => pay_periods.size }
            }
          }
        end

        def show
          render json: {
            pay_period: pay_period_summary(@pay_period, include_items: true)
          }
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.reportable_committed
                                 .where(company_id: current_company_id)
                                 .includes(payroll_items: :employee)
                                 .find_by(id: params[:id])
          return if @pay_period

          render json: { error: "Pay period not found" }, status: :not_found
        end

        def pay_period_summary(pay_period, include_items: false)
          items = pay_period.payroll_items.to_a
          json = {
            id: pay_period.id,
            company_id: pay_period.company_id,
            start_date: pay_period.start_date,
            end_date: pay_period.end_date,
            pay_date: pay_period.pay_date,
            status: pay_period.status,
            notes: pay_period.notes,
            period_description: pay_period.period_description,
            employee_count: items.size,
            total_gross: items.sum(&:gross_pay),
            total_net: items.sum(&:net_pay),
            committed_at: pay_period.committed_at,
            created_at: pay_period.created_at,
            updated_at: pay_period.updated_at
          }

          if include_items
            json[:payroll_items] = items.map do |item|
              {
                id: item.id,
                employee_id: item.employee_id,
                employee_name: item.employee_full_name,
                employment_type: item.employment_type,
                pay_rate: item.pay_rate,
                total_hours: item.total_hours,
                hours_worked: item.hours_worked,
                gross_pay: item.gross_pay,
                total_deductions: item.total_deductions,
                net_pay: item.net_pay
              }
            end
          end

          json
        end
      end
    end
  end
end
