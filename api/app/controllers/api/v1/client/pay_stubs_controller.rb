# frozen_string_literal: true

module Api
  module V1
    module Client
      class PayStubsController < BaseController
        rescue_from PayrollComponentMirrors::AmbiguousHistoryError, PayrollInsuranceComponents::AmbiguousHistoryError do |error|
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def index
          employee = Employee.where(company_id: current_company_id).find(params[:employee_id])
          items = eligible_items.where(employee_id: employee.id).includes(:pay_period).order("pay_periods.pay_date DESC", id: :desc)
          render json: { pay_stubs: items.map { |item|
            { id: item.id, pay_period_id: item.pay_period_id, pay_date: item.pay_period.pay_date,
              period_description: item.pay_period.period_description, net_pay: item.net_pay }
          } }
        end

        def download
          item = eligible_items.includes(:employee, :pay_period).find(params[:id])
          generator = PayStubGenerator.new(item, pay_period_scope: finished_periods)
          pdf = generator.generate
          # Record successful generation before sending; audit failures must not
          # silently produce an unaudited earnings-statement download.
          AuditLog.record!(
            user: current_user, company_id: current_company_id,
            action: "client_pay_stubs#download", record_type: "PayrollItem", record_id: item.id,
            metadata: { employee_id: item.employee_id, pay_period_id: item.pay_period_id },
            ip_address: request.remote_ip, user_agent: request.user_agent, request_id: request.request_id
          )
          @skip_default_audit_log = true
          response.headers["Cache-Control"] = "private, no-store"
          send_data pdf, filename: generator.filename, type: "application/pdf", disposition: "attachment"
        end

        private

        def finished_periods
          PayPeriod.client_finished.where(company_id: current_company_id)
        end

        def eligible_items
          PayrollItem.financially_reportable.reportable
            .where(company_id: current_company_id, pay_period_id: finished_periods.select(:id))
            .where(employee_id: Employee.where(company_id: current_company_id).select(:id))
        end
      end
    end
  end
end
