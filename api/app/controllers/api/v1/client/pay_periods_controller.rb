# frozen_string_literal: true

module Api
  module V1
    module Client
      class PayPeriodsController < BaseController
        audit_actions :approve_review
        before_action :set_pay_period, only: %i[show approve_review]

        def index
          result = PayrollHistoryQuery.new(
            company_id: current_company_id,
            params: params,
            audience: :client
          ).call
          render json: {
            pay_periods: result.data,
            meta: result.meta
          }
        end

        def show
          render json: {
            pay_period: pay_period_summary(@pay_period, include_items: true)
          }
        end

        def approve_review
          unless current_user&.client?
            return render json: { error: "A client portal user must approve this payroll revision." }, status: :forbidden
          end

          review_package = PayrollReview::RevisionService.new(pay_period: @pay_period, actor: current_user).approve!(
            approver: current_user,
            recorded_by: current_user,
            method: "client_portal",
            acknowledgement: params[:acknowledgement],
            notes: params[:notes]
          )
          render json: { payroll_review: PayrollReview::PackagePresenter.call(review_package) }
        rescue PayrollReview::RevisionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_pay_period
          scope = PayPeriod.reportable_periods.where(company_id: current_company_id)
          @pay_period = scope.includes(payroll_items: :employee).find_by(id: params[:id])
          @pay_period = nil unless client_visible_period?(@pay_period)
          return if @pay_period

          render json: { error: "Pay period not found" }, status: :not_found
        end

        def pay_period_summary(pay_period, include_items: false)
          items = pay_period.payroll_items.reject(&:voided?)
          json = {
            id: pay_period.id,
            company_id: pay_period.company_id,
            start_date: pay_period.start_date,
            end_date: pay_period.end_date,
            pay_date: pay_period.pay_date,
            status: pay_period.status,
            run_purpose: pay_period.run_purpose,
            includes_base_salary: pay_period.includes_base_salary,
            includes_recurring_items: pay_period.includes_recurring_items,
            notes: pay_period.notes,
            period_description: pay_period.period_description,
            employee_count: items.size,
            total_gross: items.sum(&:gross_pay),
            total_net: items.sum(&:net_pay),
            committed_at: pay_period.committed_at,
            created_at: pay_period.created_at,
            updated_at: pay_period.updated_at
          }

          json[:client_payroll_approval_required] = pay_period.company.client_payroll_approval_required?
          json[:payroll_review] = PayrollReview::PackagePresenter.call(
            pay_period.payroll_review_packages.current.includes(:generated_by, :approved_by, :approval_recorded_by).order(revision: :desc).first
          )

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
                overtime_hours: item.overtime_hours,
                gross_pay: item.gross_pay,
                withholding_tax: item.withholding_tax,
                social_security_tax: item.social_security_tax,
                medicare_tax: item.medicare_tax,
                additional_medicare_tax: item.additional_medicare_tax,
                state_withheld: 0,
                retirement_payment: item.retirement_payment,
                roth_retirement_payment: item.roth_retirement_payment,
                loan_payment: item.loan_payment,
                loan_deduction: item.loan_deduction,
                insurance_payment: item.insurance_payment,
                custom_deductions: item.custom_deductions || [],
                payroll_adjustments: item.payroll_adjustments || [],
                total_deductions: item.total_deductions,
                net_pay: item.net_pay
              }
            end
          end

          json
        end

        def client_visible_period?(pay_period)
          return false unless pay_period
          return true if pay_period.committed?

          pay_period.company.client_payroll_approval_required? &&
            pay_period.status.in?(%w[calculated approved]) &&
            pay_period.payroll_review_packages.current.exists?
        end
      end
    end
  end
end
