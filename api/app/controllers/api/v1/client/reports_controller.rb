# frozen_string_literal: true

module Api
  module V1
    module Client
      class ReportsController < Api::V1::Admin::ReportsController
        skip_before_action :require_staff_access!
        before_action :require_client_portal_access!
        before_action :ensure_client_reportable_pay_period!, only: [ :payroll_register, :payroll_register_pdf ]

        def ytd_summary
          year = params[:year]&.to_i || Date.current.year
          employees = Employee.where(company_id: current_company_id).order(:last_name, :first_name)

          render json: {
            report: {
              type: "ytd_summary",
              year: year,
              employees: employees.map { |employee| client_employee_ytd_row(employee, year) },
              company_totals: ytd_company_totals(year)
            }
          }
        end

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

          [ payroll_register_report_data(pay_period), nil ]
        end

        def ensure_client_reportable_pay_period!
          pay_period_id = params[:pay_period_id]
          return if pay_period_id.blank?

          pay_period = PayPeriod.reportable_committed.find_by(id: pay_period_id, company_id: current_company_id)
          return if pay_period

          render json: { error: "Pay period not found" }, status: :not_found
        end

        def payroll_register_report_data(pay_period)
          items = pay_period.payroll_items
          w2_items = items.reject { |item| item.employment_type == "contractor" }
          contractor_items = items.select { |item| item.employment_type == "contractor" }

          {
            type: "payroll_register",
            meta: { generated_at: Time.current.iso8601 },
            pay_period: {
              id: pay_period.id,
              start_date: pay_period.start_date,
              end_date: pay_period.end_date,
              pay_date: pay_period.pay_date,
              status: pay_period.status
            },
            summary: {
              employee_count: w2_items.size,
              contractor_count: contractor_items.size,
              total_gross: w2_items.sum(&:gross_pay),
              total_withholding: w2_items.sum(&:withholding_tax),
              total_additional_withholding: w2_items.sum(&:additional_withholding),
              total_social_security: w2_items.sum(&:social_security_tax),
              total_medicare: w2_items.sum(&:medicare_tax),
              total_retirement: w2_items.sum(&:retirement_payment).to_f + w2_items.sum(&:roth_retirement_payment).to_f,
              total_deductions: w2_items.sum(&:total_deductions),
              total_net: w2_items.sum(&:net_pay),
              contractor_total_gross: contractor_items.sum(&:gross_pay),
              contractor_total_net: contractor_items.sum(&:net_pay)
            },
            employees: w2_items.map { |item| client_payroll_item_detail(item) },
            contractors: contractor_items.map { |item| client_payroll_item_detail(item) }
          }
        end

        def client_payroll_item_detail(item)
          payroll_item_detail(item).except(:check_number)
        end

        def client_employee_ytd_row(employee, year)
          reportable_period_ids = PayPeriod.reportable_committed
                                           .where(company_id: current_company_id)
                                           .where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
                                           .select(:id)
          items = employee.payroll_items
                          .joins(:pay_period)
                          .where(pay_periods: { id: reportable_period_ids })

          {
            employee_id: employee.id,
            name: employee.full_name,
            employment_type: employee.employment_type,
            status: employee.status,
            gross_pay: items.sum(:gross_pay),
            withholding_tax: items.sum(:withholding_tax),
            social_security_tax: items.sum(:social_security_tax),
            medicare_tax: items.sum(:medicare_tax),
            retirement: items.sum(:retirement_payment),
            net_pay: items.sum(:net_pay)
          }
        end
      end
    end
  end
end
