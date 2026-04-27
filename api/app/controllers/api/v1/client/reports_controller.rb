# frozen_string_literal: true

module Api
  module V1
    module Client
      class ReportsController < Api::V1::Admin::ReportsController
        skip_before_action :require_staff_access!
        before_action :require_client_portal_access!
        before_action :ensure_client_reportable_pay_period!, only: [ :payroll_register, :payroll_register_pdf ]

        private

        def require_client_portal_access!
          return if current_user&.admin? || current_user&.manager? || current_user&.accountant? || current_user&.client?

          render json: { error: "Client portal access required" }, status: :forbidden
        end

        def current_pay_period_summary
          pp = PayPeriod.reportable_committed
                        .where(company_id: current_company_id)
                        .order(pay_date: :desc)
                        .first

          return nil unless pp

          {
            id: pp.id,
            period_description: pp.period_description,
            pay_date: pp.pay_date,
            status: pp.status,
            employee_count: pp.payroll_items.count,
            total_gross: pp.payroll_items.sum(:gross_pay),
            total_net: pp.payroll_items.sum(:net_pay)
          }
        end

        def recent_payroll_summary
          PayPeriod.reportable_committed
                   .where(company_id: current_company_id)
                   .includes(:payroll_items)
                   .order(pay_date: :desc)
                   .limit(5)
                   .map do |pp|
            {
              id: pp.id,
              period_description: pp.period_description,
              pay_date: pp.pay_date,
              employee_count: pp.payroll_items.size,
              total_net: pp.payroll_items.sum(&:net_pay)
            }
          end
        end

        def build_payroll_register_data
          pay_period_id = params[:pay_period_id]
          if pay_period_id.blank?
            return [ nil, render(json: { error: "pay_period_id is required" }, status: :unprocessable_entity) ]
          end

          pay_period = PayPeriod.reportable_committed
                                .includes(payroll_items: :employee)
                                .find_by(id: pay_period_id, company_id: current_company_id)

          unless pay_period
            return [ nil, render(json: { error: "Pay period not found" }, status: :not_found) ]
          end

          super
        end

        def ensure_client_reportable_pay_period!
          pay_period_id = params[:pay_period_id]
          return if pay_period_id.blank?

          pay_period = PayPeriod.reportable_committed.find_by(id: pay_period_id, company_id: current_company_id)
          return if pay_period

          render json: { error: "Pay period not found" }, status: :not_found
        end
      end
    end
  end
end
