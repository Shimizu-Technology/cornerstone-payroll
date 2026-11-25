# frozen_string_literal: true

module Api
  module V1
    module Client
      class ReportsController < Api::V1::Admin::ReportsController
        include ClientPortalAccess

        skip_before_action :require_staff_access!
        before_action :require_client_portal_access!
        before_action :ensure_client_reportable_pay_period!, only: %i[
          payroll_register
          payroll_register_csv
          payroll_register_pdf
          payroll_register_xlsx
        ]

        def ytd_summary
          render json: { report: build_period_summary_report(payroll_reporting_period) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def report_meta(company, report_key)
          super.merge(payroll_status_note: company&.practice_copy? ? "TEST ONLY — finished copied history and committed payroll" : nil)
        end

        def report_pay_periods
          PayPeriod.client_finished.where(company_id: current_company_id)
        end

        def annual_report_pay_periods
          report_pay_periods
        end

        def loan_report_pay_periods
          report_pay_periods
        end

        def client_report_view?
          true
        end

        def find_pay_period_for_report
          id = params[:pay_period_id]
          if id.blank?
            render json: { error: "pay_period_id is required" }, status: :unprocessable_entity
            return nil
          end
          period = report_pay_periods.find_by(id: id)
          render json: { error: "Pay period not found" }, status: :not_found unless period
          period
        end

        def current_pay_period_summary
          pp = PayPeriod.client_finished
                        .where(company_id: current_company_id)
                        .order(pay_date: :desc)
                        .first

          return nil unless pp

          {
            id: pp.id,
            period_description: pp.period_description,
            pay_date: pp.pay_date,
            status: pp.status,
            employee_count: pp.payroll_items.financially_reportable.reportable.count,
            total_gross: pp.payroll_items.financially_reportable.reportable.sum(:gross_pay),
            total_net: pp.payroll_items.financially_reportable.reportable.sum(:net_pay)
          }
        end

        def recent_payroll_summary
          PayPeriod.client_finished
                   .where(company_id: current_company_id)
                   .includes(:payroll_items)
                   .order(pay_date: :desc)
                   .limit(5)
                   .map do |pp|
            {
              id: pp.id,
              period_description: pp.period_description,
              pay_date: pp.pay_date,
              employee_count: pp.payroll_items.reportable.select(&:payroll_included?).size,
              total_net: pp.payroll_items.reportable.select(&:payroll_included?).sum(&:net_pay)
            }
          end
        end

        def build_payroll_register_data
          pay_period_id = params[:pay_period_id]
          if pay_period_id.blank?
            return [ nil, render(json: { error: "pay_period_id is required" }, status: :unprocessable_entity) ]
          end

          pay_period = report_pay_periods.find_by(id: pay_period_id)

          unless pay_period
            return [ nil, render(json: { error: "Pay period not found" }, status: :not_found) ]
          end

          [ native_payroll_register_report(pay_period), nil ]
        end

        def ensure_client_reportable_pay_period!
          pay_period_id = params[:pay_period_id]
          return if pay_period_id.blank?

          pay_period = PayPeriod.client_finished.find_by(id: pay_period_id, company_id: current_company_id)
          return if pay_period

          render json: { error: "Pay period not found" }, status: :not_found
        end
      end
    end
  end
end
