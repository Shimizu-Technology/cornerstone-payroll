# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollFinalRecordsController < BaseController
        before_action :load_pay_period

        def show
          no_store!
          render json: { final_record: record }
        rescue PayrollFinalRecordService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def xlsx
          no_store!
          exporter = SpreadsheetReportExporter.new(filename: filename("xlsx"), sheets: sheets(record))
          send_data exporter.generate,
                    filename: exporter.filename,
                    type: SpreadsheetReportExporter::CONTENT_TYPE,
                    disposition: "attachment"
        rescue PayrollFinalRecordService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def pdf
          no_store!
          payload = record
          generator = TabularReportPdfGenerator.new(
            title: "Final Payroll Record",
            subtitle: "#{payload.dig(:company, :name)} — #{payload.dig(:pay_period, :start_date)} through #{payload.dig(:pay_period, :end_date)}",
            filename: filename("pdf"),
            sheets: sheets(payload)
          )
          send_data generator.generate,
                    filename: generator.filename,
                    type: "application/pdf",
                    disposition: "attachment"
        rescue PayrollFinalRecordService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def load_pay_period
          @pay_period = PayPeriod.includes(:company).find_by(id: params[:pay_period_id], company_id: current_company_id)
          render json: { error: "Pay period not found" }, status: :not_found unless @pay_period
        end

        def record
          @record ||= PayrollFinalRecordService.new(pay_period: @pay_period).call
        end

        def filename(extension)
          "final_payroll_record_#{@pay_period.start_date}_through_#{@pay_period.end_date}.#{extension}"
        end

        def no_store!
          response.headers["Cache-Control"] = "no-store"
        end

        def sheets(payload)
          [
            overview_sheet(payload),
            journal_sheet(payload),
            employee_payments_sheet(payload),
            liabilities_sheet(payload),
            ytd_sheet(payload),
            evidence_sheet(payload)
          ]
        end

        def overview_sheet(payload)
          payroll = payload.fetch(:official_payroll)
          completion = payload.fetch(:completion)
          period = payload.fetch(:pay_period)
          {
            name: "Overview",
            rows: [
              [ "Final Payroll Record", payload.dig(:company, :name) ],
              [ "Period", "#{period[:start_date]} through #{period[:end_date]}" ],
              [ "Pay date", period[:pay_date] ],
              [ "Payroll status", payroll[:status].to_s.humanize ],
              [ "Closeout status", completion[:status].to_s.humanize ],
              [ "Paychecks", payroll[:paycheck_count] ],
              [ "Gross pay", payroll[:gross_pay] ],
              [ "Non-taxable pay", payroll[:non_taxable_pay] ],
              [ "Employee deductions", payroll[:employee_deductions] ],
              [ "Net pay", payroll[:net_pay] ],
              [ "Employer taxes", payroll[:employer_taxes] ],
              [ "Employer contributions", payroll[:employer_contributions] ],
              [ "Total payroll cost", payroll[:total_payroll_cost] ],
              [ "Calculation checksum", payroll[:calculation_checksum] ],
              [ "Record fingerprint", payload[:record_fingerprint] ],
              [],
              [ "Blocking items" ],
              *completion[:blockers].map { |item| [ item ] },
              [],
              [ "Open settlement items" ],
              *completion[:open_items].map { |item| [ item ] }
            ]
          }
        end

        def journal_sheet(payload)
          journal = payload.fetch(:journal)
          {
            name: "Balanced Journal",
            rows: [
              [ "Reference category", "Debit", "Credit", "Source" ],
              *journal[:lines].map { |line| [ line[:account_label], line[:debit], line[:credit], line[:source] ] },
              [ "Total", journal[:debit_total], journal[:credit_total], journal[:balanced] ? "BALANCED" : "OUT OF BALANCE" ],
              [ "Difference", journal[:difference] ],
              [],
              [ journal[:basis] ]
            ]
          }
        end

        def employee_payments_sheet(payload)
          rows = payload.dig(:employee_payments, :rows)
          {
            name: "Employee Checks",
            rows: [
              [ "Employee", "Net pay", "Check number", "Issuance status", "Reconciliation status" ],
              *rows.map { |row| [ row[:employee_name], row[:amount], row[:check_number], row[:issuance_status].humanize, row[:reconciliation_status].humanize ] }
            ]
          }
        end

        def liabilities_sheet(payload)
          liabilities = payload.fetch(:liabilities)
          {
            name: "Payroll Liabilities",
            rows: [
              [ "Recipient", "Liability date", "Due date", "Calculated", "Prepared", "Paid", "Outstanding", "Status" ],
              *liabilities[:obligations].map do |row|
                [ row[:authority], row[:liability_date], row[:due_date], row[:calculated_amount], row[:prepared_amount], row[:paid_amount], row[:outstanding_amount], row[:status].humanize ]
              end,
              [],
              [ "Total", nil, nil, liabilities[:calculated_amount], liabilities[:prepared_amount], liabilities[:paid_amount], liabilities[:outstanding_amount] ],
              [ "Posting status", liabilities[:posting_status].humanize ],
              [ "Payment tracking", liabilities[:payment_tracking_status].humanize ]
            ]
          }
        end

        def ytd_sheet(payload)
          ytd = payload.fetch(:ytd_reconciliation)
          {
            name: "YTD Reconciliation",
            rows: [
              [ "Status", ytd[:status].humanize ],
              [ "Through pay date", ytd[:through_pay_date] ],
              [ "Cornerstone payrolls", ytd[:cornerstone_payroll_count] ],
              [ "Cornerstone paychecks", ytd[:cornerstone_paycheck_count] ],
              [ "QuickBooks paychecks", ytd[:quickbooks_paycheck_count] ],
              [ "Historical adjustments", ytd[:historical_adjustment_count] ],
              [ "Unlinked historical paychecks", ytd[:excluded_unlinked_paycheck_count] ],
              [],
              [ "Measure", "YTD total" ],
              *ytd[:totals].map { |key, value| [ key.to_s.humanize, value ] }
            ]
          }
        end

        def evidence_sheet(payload)
          evidence = payload.fetch(:evidence)
          review = evidence[:review]
          rows = [ [ "Evidence type", "Reference", "SHA-256 / checksum", "Detail" ] ]
          payroll_approval = evidence[:payroll_approval]
          rows << [ "Payroll approval", payroll_approval[:approved_at], nil, payroll_approval[:approved_by_name] ] if payroll_approval[:approved_at]
          if review
            rows << [ "Approved payroll review", "Revision #{review[:revision]}", review[:calculation_checksum], "#{review[:approval_method].to_s.humanize} — #{review[:approved_by_name]}" ]
          end
          evidence[:source_packages].each do |package|
            rows << [ "Payroll source package", package[:package_id], package[:import_hash], package[:source_type].to_s.humanize ]
            package[:documents].each do |document|
              rows << [ "Source document", document["filename"], document["sha256"], document["source_role"].to_s.humanize ]
            end
          end
          evidence[:time_tracking_imports].each do |time_import|
            rows << [ "Timekeeping batch", time_import["external_batch_id"] || time_import["id"], time_import["external_batch_checksum"], time_import["contract_version"] ]
          end
          { name: "Evidence", rows: }
        end
      end
    end
  end
end
