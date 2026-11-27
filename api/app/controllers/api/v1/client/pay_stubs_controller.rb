# frozen_string_literal: true

module Api
  module V1
    module Client
      class PayStubsController < BaseController
        include ClientComponentHistoryErrors

        def index
          employee = Employee.where(company_id: current_company_id).find(params[:employee_id])
          items = eligible_items.where(employee_id: employee.id).includes(:pay_period).newest_printed_first.to_a
          documents = EmployeeDocument.posted_by_payroll_item(employee.company_id, items.map(&:id))
          quickbooks_paychecks = EmployeeDocuments::QuickbooksHistory.for(employee).map do |check|
            {
              id: check[:historical_paycheck_id],
              pay_date: check[:pay_date],
              period_start: check[:period_start],
              period_end: check[:period_end],
              gross_pay: check[:gross_pay],
              net_pay: check[:net_pay],
              hours_total: check[:hours_total],
              source_label: check[:source_label],
              adjustment_note: check[:adjustment_note]
            }
          end
          render json: {
            pay_stubs: items.select { |item| EarningsStatementEligibility.printable?(item) }.map { |item|
              # pay_date is the date the stub prints (the check's own date, else the run's).
              { id: item.id, pay_period_id: item.pay_period_id, pay_date: item.check_date || item.pay_period.pay_date,
                period_pay_date: item.pay_period.pay_date,
                start_date: item.pay_period.start_date, end_date: item.pay_period.end_date,
                period_description: item.pay_period.period_description, net_pay: item.net_pay,
                corrected: documents[item.id]&.correction_label? || false }
            },
            quickbooks_paychecks: quickbooks_paychecks
          }
        end

        def download
          item = eligible_items.includes(:employee, :pay_period).find(params[:id])
          unless EarningsStatementEligibility.printable?(item)
            return render json: { error: "This payroll item has no earnings activity to print an earnings statement." }, status: :unprocessable_entity
          end

          generator = PayStubGenerator.new(item)
          pdf = generator.generate
          # Record successful generation before sending; audit failures must not
          # silently produce an unaudited earnings-statement download.
          AuditLog.record!(
            user: current_user, company_id: current_company_id,
            action: "client_pay_stubs#download", event_category: "document_access", record_type: "PayrollItem", record_id: item.id,
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
