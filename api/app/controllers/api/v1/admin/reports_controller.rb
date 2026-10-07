# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ReportsController < BaseController
        EXTERNAL_FILING_OUTCOME_FIELDS = %i[
          filed_at
          paid_at
          payment_amount
          filing_confirmation_number
          payment_confirmation_number
          proof_attached
        ].freeze

        REPORT_DESCRIPTIONS = {
          payroll_register: "Full payroll detail for the selected pay period, including hours, earnings, taxes, deductions, employer taxes, net pay, and check numbers.",
          payroll_summary_by_employee: "Employee-by-employee payroll summary for the selected pay period, including earnings, deductions, taxes, employer contributions, and total payroll cost.",
          deductions_contributions: "Detailed employee deductions and employer contribution activity for the selected pay period.",
          paycheck_history: "Check numbers, check dates, earnings, deductions, and net pay for payroll items in the selected pay period.",
          retirement_plans: "401(k), Roth 401(k), and employer retirement contribution activity for the selected pay period.",
          tax_summary: "Payroll tax withholding summary used to review Guam/federal payroll tax liability for the selected year or quarter.",
          ytd_summary: "Payroll totals by worker for the selected tax year or pay-date range.",
          annual_payroll_summary: "Year-by-year payroll totals across locked QuickBooks imports and committed Cornerstone payroll.",
          employee_pay_history: "Paycheck history for an individual worker, including recent pay periods and year-to-date totals.",
          form_941_gu: "Federal Form 941 preparation worksheet for Guam employers, with Guam-specific line 2/3 skip handling and FICA liability detail.",
          quarterly_compliance_packet: "Quarterly Guam and federal payroll filing packet covering Form 500, W-1, SWICA, Federal Form 941, and review tie-outs.",
          w2_gu: "W-2GU preparation workbook for W-2 employees for the selected tax year.",
          form_1099_nec: "1099-NEC preparation workbook for contractor compensation and filing readiness.",
          installment_loans: "Employee installment loan balances and transaction history as of the selected date."
        }.freeze
        OFFICIAL_FORM_STRING_LIMIT = 250
        OFFICIAL_FORM_DAILY_LIABILITY_LIMIT = 120
        OFFICIAL_FORM_SWICA_EMPLOYEE_LIMIT = 500
        OFFICIAL_FORM_COMPANY_FIELDS = %i[
          company_name ein company_address company_address_line1 company_address_line2
          company_city company_state company_zip
        ].freeze
        OFFICIAL_FORM_941_LINE_FIELDS = %i[
          line1_employee_count line5a_ss_wages line5a_ss_combined_tax
          line5b_ss_tips line5b_ss_tips_combined_tax line5c_medicare_wages
          line5c_medicare_combined_tax line5d_add_medicare_wages
          line5d_add_medicare_tax line5e_total_ss_medicare
          line6_total_taxes_before_adj line7_adj_fractions_cents
          line10_total_taxes_after_adj line12_total_after_credits
        ].freeze

        # GET /api/v1/admin/reports/dashboard
        # Dashboard stats and metrics
        def dashboard
          render json: {
            stats: {
              total_employees: Employee.where(company_id: current_company_id).count,
              active_employees: Employee.active.where(company_id: current_company_id).count,
              current_pay_period: current_pay_period_summary,
              ytd_totals: ytd_company_totals,
              recent_payrolls: recent_payroll_summary
            }
          }
        end

        # GET /api/v1/admin/reports/payroll_register
        # Detailed payroll for a pay period
        def payroll_register
          report_data, error_response = build_payroll_register_data
          return error_response if error_response

          render json: { report: report_data }
        end

        # GET /api/v1/admin/reports/payroll_register_csv
        # Downloads payroll register as CSV for the given pay period.
        def payroll_register_csv
          report_data, error_response = build_payroll_register_data
          return error_response if error_response

          exporter = PayrollRegisterCsvExporter.new(report_data)
          send_data exporter.generate,
            filename: exporter.filename,
            type: "text/csv; charset=utf-8",
            disposition: "attachment"
        end

        # GET /api/v1/admin/reports/payroll_register_pdf
        # Downloads payroll register as PDF for the given pay period.
        def payroll_register_pdf
          report_data, error_response = build_payroll_register_data
          return error_response if error_response

          generator = PayrollRegisterPdfGenerator.new(report_data)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        end

        def payroll_register_xlsx
          report_data, error_response = build_payroll_register_data
          return error_response if error_response

          send_spreadsheet!(
            filename: PayrollRegisterCsvExporter.new(report_data).filename.sub(/\.csv\z/, ".xlsx"),
            sheets: payroll_register_sheets(report_data)
          )
        end

        # GET /api/v1/admin/reports/employee_pay_history
        # Individual employee pay records
        def employee_pay_history
          employee = Employee.find(params[:employee_id])

          unless employee.company_id == current_company_id
            return render json: { error: "Employee not found" }, status: :not_found
          end

          period = employee_pay_history_period
          items = employee_pay_history_items(employee, period)

          render json: {
            report: employee_pay_history_report(employee, items, period: period)
          }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def employee_pay_history_xlsx
          employee, period, report = employee_pay_history_export_data
          return if performed?

          send_spreadsheet!(
            filename: "employee_pay_history_#{employee.last_name}_#{employee.first_name}_#{period.filename_token}.xlsx",
            sheets: employee_pay_history_sheets(report)
          )
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def employee_pay_history_pdf
          employee, period, report = employee_pay_history_export_data
          return if performed?

          send_tabular_pdf!(
            title: "Employee Pay History",
            subtitle: "#{employee.full_name} — #{period.label}",
            filename: "employee_pay_history_#{employee.last_name}_#{employee.first_name}_#{period.filename_token}.pdf",
            sheets: employee_pay_history_sheets(report)
          )
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def employee_pay_history_csv
          employee, period, report = employee_pay_history_export_data
          return if performed?

          send_tabular_csv!(
            filename: "employee_pay_history_#{employee.last_name}_#{employee.first_name}_#{period.filename_token}.csv",
            sheet: employee_pay_history_sheets(report).first
          )
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/reports/tax_summary
        # Tax withholding summary (for quarterly filing)
        def tax_summary
          report_data, error_response = build_tax_summary_data
          return error_response if error_response

          render json: { report: report_data }
        end

        # GET /api/v1/admin/reports/tax_summary_csv
        # Downloads tax summary as CSV.
        # Params: year (optional, defaults to current year), quarter (optional, 1-4)
        def tax_summary_csv
          report_data, error_response = build_tax_summary_data
          return error_response if error_response

          exporter = TaxSummaryCsvExporter.new(report_data)
          send_data exporter.generate,
            filename: exporter.filename,
            type: "text/csv; charset=utf-8",
            disposition: "attachment"
        end

        # GET /api/v1/admin/reports/tax_summary_pdf
        # Downloads tax summary as PDF.
        # Params: year (optional, defaults to current year), quarter (optional, 1-4)
        def tax_summary_pdf
          report_data, error_response = build_tax_summary_data
          return error_response if error_response

          generator = TaxSummaryPdfGenerator.new(report_data)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        end

        def tax_summary_xlsx
          report_data, error_response = build_tax_summary_data
          return error_response if error_response

          send_spreadsheet!(
            filename: TaxSummaryCsvExporter.new(report_data).filename.sub(/\.csv\z/, ".xlsx"),
            sheets: tax_summary_sheets(report_data)
          )
        end

        # Employer-only FICA liability is a distinct report surface. It shares
        # the tax-summary source data but exports only the employer obligations
        # shown in the in-app preview.
        def employer_liability
          report_data, error_response = build_tax_summary_data
          return error_response if error_response

          render json: { report: report_data.merge(type: "employer_liability") }
        end

        def employer_liability_csv
          report_data, error_response = build_tax_summary_data
          return error_response if error_response

          send_tabular_csv!(
            filename: "employer_tax_liability_#{report_period_filename_token(report_data)}.csv",
            sheet: employer_liability_sheets(report_data).first
          )
        end

        def employer_liability_pdf
          report_data, error_response = build_tax_summary_data
          return error_response if error_response

          send_tabular_pdf!(
            title: "Employer Tax Liability",
            subtitle: "#{report_data.dig(:meta, :company_name)} — #{report_data.dig(:period, :label)}",
            filename: "employer_tax_liability_#{report_period_filename_token(report_data)}.pdf",
            sheets: employer_liability_sheets(report_data)
          )
        end

        def employer_liability_xlsx
          report_data, error_response = build_tax_summary_data
          return error_response if error_response

          send_spreadsheet!(
            filename: "employer_tax_liability_#{report_period_filename_token(report_data)}.xlsx",
            sheets: employer_liability_sheets(report_data)
          )
        end

        # GET /api/v1/admin/reports/form_941_gu
        # Federal Form 941 worksheet. The legacy route name is preserved for
        # frontend/API compatibility while the report output uses current Guam
        # employer handling.
        #
        # Params:
        #   year    [Integer] – tax year (defaults to current year)
        #   quarter [Integer] – 1, 2, 3, or 4 (required)
        #
        # Response: structured JSON mirroring federal Form 941 line items.
        # Placeholders (nil values) indicate fields requiring manual entry before filing.
        def form_941_gu
          raw_year = params[:year]
          year = if raw_year.present?
            Integer(raw_year, exception: false)
          else
            Date.current.year
          end
          quarter = params[:quarter]&.to_i

          unless year && year > 2000 && year <= Date.current.year + 1
            return render json: {
              error: "year must be a valid 4-digit tax year"
            }, status: :unprocessable_entity
          end

          unless quarter && (1..4).cover?(quarter)
            return render json: {
              error: "quarter is required and must be 1, 2, 3, or 4"
            }, status: :unprocessable_entity
          end

          company = Company.find(current_company_id)
          report  = Form941GuAggregator.new(company, year, quarter).generate
          report[:filing_gate] = PayrollFilingResponsibilityGate.new(
            company: company,
            tax_year: year,
            quarter: quarter,
            filing_type: "form_941"
          ).payload

          render json: { report: report }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def form_941_gu_xlsx
          raw_year = params[:year]
          year = raw_year.present? ? Integer(raw_year, exception: false) : Date.current.year
          quarter = params[:quarter]&.to_i

          unless year && year > 2000 && year <= Date.current.year + 1
            return render json: { error: "year must be a valid 4-digit tax year" }, status: :unprocessable_entity
          end

          unless quarter && (1..4).cover?(quarter)
            return render json: { error: "quarter is required and must be 1, 2, 3, or 4" }, status: :unprocessable_entity
          end

          company = Company.find(current_company_id)
          report = Form941GuAggregator.new(company, year, quarter).generate
          send_spreadsheet!(
            filename: "federal_form_941_#{year}_q#{quarter}.xlsx",
            sheets: form_941_gu_sheets(report)
          )
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def form_941_gu_pdf
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          send_data QuarterlyComplianceOfficialForms::Form941.new(report: report_data).generate,
            filename: "federal_form_941_draft_#{report_data.dig(:meta, :year)}_q#{report_data.dig(:meta, :quarter)}.pdf",
            type: "application/pdf",
            disposition: "attachment"
        rescue OfficialPdfOverlay::TemplateUnavailableError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def quarterly_compliance_packet
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          render json: { report: report_data }
        end

        def start_quarterly_compliance_packet_workflow
          year, quarter, company, error_response = quarterly_compliance_packet_context
          return error_response if error_response

          QuarterlyCompliancePacket.find_or_create_for!(
            company: company,
            year: year,
            quarter: quarter,
            user: current_user
          )
          report = QuarterlyCompliancePacketBuilder.new(company, year, quarter).generate
          report[:filing_gate] = PayrollFilingResponsibilityGate.quarterly(
            company: company,
            tax_year: year,
            quarter: quarter
          )
          render json: { report: report }, status: :created
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def quarterly_compliance_packet_xlsx
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          send_spreadsheet!(
            filename: "quarterly_compliance_packet_#{report_data.dig(:meta, :year)}_q#{report_data.dig(:meta, :quarter)}.xlsx",
            sheets: quarterly_compliance_packet_sheets(report_data)
          )
        end

        def quarterly_compliance_packet_pdf
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          generator = QuarterlyCompliancePacketPdfGenerator.new(report_data)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        rescue OfficialPdfOverlay::TemplateUnavailableError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def quarterly_compliance_packet_form_941_pdf
          send_quarterly_compliance_official_form!(
            generator: QuarterlyComplianceOfficialForms::Form941,
            filename_prefix: "federal_form_941_draft"
          )
        end

        def quarterly_compliance_packet_schedule_b_pdf
          send_quarterly_compliance_official_form!(
            generator: QuarterlyComplianceOfficialForms::ScheduleB,
            filename_prefix: "federal_form_941_schedule_b_draft"
          )
        end

        def quarterly_compliance_packet_w1_pdf
          send_quarterly_compliance_official_form!(
            generator: QuarterlyComplianceOfficialForms::W1,
            filename_prefix: "guam_w1_draft"
          )
        end

        def quarterly_compliance_packet_swica_pdf
          send_quarterly_compliance_official_form!(
            generator: QuarterlyComplianceOfficialForms::Sw2,
            filename_prefix: "guam_sw2_draft"
          )
        end

        def quarterly_compliance_packet_swica_ascii
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          unless report_data.dig(:swica, :wage_record_export_ready)
            return render json: {
              error: report_data.dig(:swica, :wage_record_export_note),
              details: report_data.dig(:swica, :wage_record_validation_errors)
            }, status: :unprocessable_entity
          end

          exporter = SwicaAsciiExporter.new(report_data)
          send_data exporter.generate,
            filename: exporter.filename,
            type: "text/plain; charset=us-ascii",
            disposition: "attachment"
        rescue ArgumentError, KeyError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update_quarterly_compliance_packet_task
          task = QuarterlyComplianceTask.joins(:quarterly_compliance_packet)
            .where(quarterly_compliance_packets: { company_id: current_company_id })
            .find(params[:id])
          task_payload = params[:task] || {}
          requested_status = task_payload[:status].to_s
          typed_outcome = EXTERNAL_FILING_OUTCOME_FIELDS.any? { |field| task_payload.key?(field) }
          if !task.status.in?(QuarterlyComplianceTask::PREPARATION_STATUSES) &&
              requested_status.present? && requested_status != task.status
            return render json: {
              error: "Legacy status #{task.status.humanize.downcase} is retained read-only; use the filing evidence history"
            }, status: :unprocessable_entity
          end
          if requested_status.present? && !requested_status.in?(QuarterlyComplianceTask::PREPARATION_STATUSES)
            message = if requested_status.in?(QuarterlyComplianceTask::STATUSES)
              "Status #{requested_status.humanize.downcase} is read-only; filing and payment outcomes require retained agency evidence"
            else
              "Unsupported quarterly task status: #{requested_status}"
            end
            return render json: { error: message }, status: :unprocessable_entity
          end
          if typed_outcome
            return render json: {
              error: "Filing and payment outcomes must be recorded with retained agency evidence"
            }, status: :unprocessable_entity
          end
          if requested_status == "ready_to_file"
            filing_gate = PayrollFilingResponsibilityGate.for_task(task)
            unless filing_gate.dig(:capabilities, :can_mark_filing_ready)
              return render json: {
                error: "Resolve payroll filing responsibility before marking this filing ready",
                filing_gate: filing_gate
              }, status: :unprocessable_entity
            end
          end
          task.update!(quarterly_compliance_task_params)
          render json: { task: task.workflow_payload }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Task not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end

        def quarterly_compliance_packet_official_form_defaults
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          render json: {
            data: quarterly_compliance_official_form_defaults(report_data, params[:form_type]),
            filing_gate: report_data[:filing_gate]
          }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def quarterly_compliance_packet_official_form_preview
          send_quarterly_compliance_official_form_from_params!(disposition: "inline")
        end

        def quarterly_compliance_packet_official_form_download
          send_quarterly_compliance_official_form_from_params!(disposition: "attachment")
        end

        # GET /api/v1/admin/reports/w2_gu
        # Annual W-2GU summary data for filing preparation.
        # Params:
        #   year [Integer] – tax year (defaults to current year)
        def w2_gu
          report_data, error_response = build_w2_gu_report_data
          return error_response if error_response

          render json: { report: report_data }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/reports/w2_gu_csv
        # Downloads W-2GU annual summary as CSV.
        # Params:
        #   year [Integer] – tax year (defaults to current year)
        def w2_gu_csv
          report_data, error_response = build_w2_gu_report_data
          return error_response if error_response

          exporter = W2GuCsvExporter.new(report_data)
          send_data exporter.generate,
            filename: exporter.filename,
            type: "text/csv; charset=utf-8",
            disposition: "attachment"
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/reports/w2_gu_pdf
        # Downloads W-2GU annual summary as PDF.
        # Params:
        #   year [Integer] – tax year (defaults to current year)
        def w2_gu_pdf
          report_data, error_response = build_w2_gu_report_data
          return error_response if error_response

          generator = W2GuPdfGenerator.new(report_data)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def w2_gu_xlsx
          report_data, error_response = build_w2_gu_report_data
          return error_response if error_response

          send_spreadsheet!(
            filename: W2GuCsvExporter.new(report_data).filename.sub(/\.csv\z/, ".xlsx"),
            sheets: w2_gu_sheets(report_data)
          )
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/reports/form_1099_nec
        # Annual 1099-NEC summary for contractor filing preparation.
        def form_1099_nec
          year = parse_tax_year_param
          return if performed?

          company = Company.find(current_company_id)
          report = Form1099NecAggregator.new(company, year).generate
          render json: { report: report }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/reports/form_1099_nec_pdf
        # Downloads 1099-NEC annual summary as PDF.
        def form_1099_nec_pdf
          year = parse_tax_year_param
          return if performed?

          company = Company.find(current_company_id)
          report = Form1099NecAggregator.new(company, year).generate
          generator = Form1099NecPdfGenerator.new(report)
          send_data generator.generate,
            filename: "1099-NEC_#{company.name.parameterize}_#{year}.pdf",
            type: "application/pdf",
            disposition: "attachment"
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def form_1099_nec_csv
          year = parse_tax_year_param
          return if performed?

          company = Company.find(current_company_id)
          report = Form1099NecAggregator.new(company, year).generate
          send_tabular_csv!(
            filename: "1099-NEC_#{company.name.parameterize}_#{year}.csv",
            sheet: form_1099_nec_sheets(report).first
          )
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def form_1099_nec_xlsx
          year = parse_tax_year_param
          return if performed?

          company = Company.find(current_company_id)
          report = Form1099NecAggregator.new(company, year).generate
          send_spreadsheet!(
            filename: "1099-NEC_#{company.name.parameterize}_#{year}.xlsx",
            sheets: form_1099_nec_sheets(report)
          )
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/reports/w2_gu_preflight
        # Runs preflight checks and persists filing readiness state for a given tax year.
        def w2_gu_preflight
          raw_year = params[:year]
          year = if raw_year.present?
            Integer(raw_year, exception: false)
          else
            Date.current.year
          end

          unless year && year > 2000 && year <= Date.current.year + 1
            return render json: { error: "year must be a valid 4-digit tax year" }, status: :unprocessable_entity
          end

          company = Company.find(current_company_id)
          preflight = W2GuPreflightValidator.new(company: company, year: year).run

          filing = W2FilingReadiness.find_or_initialize_by(company_id: company.id, year: year)
          apply_preflight_to_filing!(
            filing,
            preflight,
            update_preflight_run_at: true
          )

          attempts = 0
          begin
            attempts += 1
            filing.save!
          rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
            raise if attempts >= 2

            filing = W2FilingReadiness.find_or_initialize_by(company_id: company.id, year: year)
            apply_preflight_to_filing!(
              filing,
              preflight,
              update_preflight_run_at: true
            )
            retry
          end

          render json: {
            preflight: preflight,
            filing: filing_readiness_payload(filing),
            filing_gate: PayrollFilingResponsibilityGate.annual(company: company, tax_year: year)
          }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
          render json: { error: "Unable to persist W-2 preflight readiness state" }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/reports/w2_gu_filing_readiness
        # Returns persisted filing readiness state for the requested year (no side effects).
        def w2_gu_filing_readiness
          raw_year = params[:year]
          year = if raw_year.present?
            Integer(raw_year, exception: false)
          else
            Date.current.year
          end

          unless year && year > 2000 && year <= Date.current.year + 1
            return render json: { error: "year must be a valid 4-digit tax year" }, status: :unprocessable_entity
          end

          company = Company.find(current_company_id)
          filing = W2FilingReadiness.find_by(company_id: company.id, year: year)
          render json: {
            filing: filing ? filing_readiness_payload(filing) : nil,
            filing_gate: PayrollFilingResponsibilityGate.annual(company: company, tax_year: year)
          }
        end

        # POST /api/v1/admin/reports/w2_gu_mark_ready
        # Marks a W-2 filing year as filing-ready if no blocking findings remain.
        def w2_gu_mark_ready
          require_admin!
          return if performed?

          raw_year = params[:year]
          year = if raw_year.present?
            Integer(raw_year, exception: false)
          else
            Date.current.year
          end

          unless year && year > 2000 && year <= Date.current.year + 1
            return render json: { error: "year must be a valid 4-digit tax year" }, status: :unprocessable_entity
          end

          filing = W2FilingReadiness.find_by(company_id: current_company_id, year: year)
          unless filing
            return render json: { error: "Run W-2 preflight before marking filing ready" }, status: :unprocessable_entity
          end

          company = Company.find(current_company_id)
          filing_gate = PayrollFilingResponsibilityGate.annual(company: company, tax_year: year)
          unless filing_gate.dig(:capabilities, :all_filing_ready_exports_allowed)
            return render json: {
              error: "Resolve payroll filing responsibility before marking W-2GU filing ready",
              filing: filing_readiness_payload(filing),
              filing_gate: filing_gate
            }, status: :unprocessable_entity
          end

          if filing.status == "filing_ready"
            return render json: { filing: filing_readiness_payload(filing), filing_gate: filing_gate }
          end

          fresh_preflight = W2GuPreflightValidator.new(company: company, year: year).run
          apply_preflight_to_filing!(
            filing,
            fresh_preflight,
            update_preflight_run_at: false
          )

          if filing.blocking_count.to_i > 0
            filing.save!
            return render json: {
              error: "Cannot mark filing ready with blocking findings",
              filing: filing_readiness_payload(filing),
              revalidation: revalidation_payload(fresh_preflight)
            }, status: :unprocessable_entity
          end

          filing.status = "filing_ready"
          filing.marked_ready_at = Time.current
          filing.marked_ready_by_id = current_user&.id
          filing.notes = params.key?(:notes) ? params[:notes].presence : filing.notes
          filing.save!

          render json: {
            filing: filing_readiness_payload(filing),
            revalidation: revalidation_payload(fresh_preflight),
            filing_gate: filing_gate
          }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Company not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid
          render json: { error: "Unable to persist W-2 filing readiness state" }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/reports/payroll_summary_by_employee_pdf
        def payroll_summary_by_employee_pdf
          pp = find_pay_period_for_report
          return unless pp

          generator = PayrollSummaryByEmployeePdfGenerator.new(pp)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        end

        def payroll_summary_by_employee_xlsx
          pp = find_pay_period_for_report
          return unless pp

          report_data = build_pay_period_payroll_items_report(pp)
          send_spreadsheet!(
            filename: "payroll_summary_by_employee_#{pp.start_date}_to_#{pp.end_date}.xlsx",
            sheets: payroll_summary_by_employee_sheets(report_data, pp)
          )
        end

        # GET /api/v1/admin/reports/deductions_contributions_pdf
        def deductions_contributions_pdf
          pp = find_pay_period_for_report
          return unless pp

          generator = DeductionsContributionsReportPdfGenerator.new(pp)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        end

        def deductions_contributions_xlsx
          pp = find_pay_period_for_report
          return unless pp

          send_spreadsheet!(
            filename: "deductions_contributions_#{pp.start_date}_to_#{pp.end_date}.xlsx",
            sheets: deductions_contributions_sheets(pp)
          )
        end

        # GET /api/v1/admin/reports/paycheck_history_pdf
        def paycheck_history_pdf
          pp = find_pay_period_for_report
          return unless pp

          generator = PaycheckHistoryPdfGenerator.new(pp)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        end

        def paycheck_history_xlsx
          pp = find_pay_period_for_report
          return unless pp

          send_spreadsheet!(
            filename: "paycheck_history_#{pp.start_date}_to_#{pp.end_date}.xlsx",
            sheets: paycheck_history_sheets(pp)
          )
        end

        # GET /api/v1/admin/reports/retirement_plans_pdf
        def retirement_plans_pdf
          pp = find_pay_period_for_report
          return unless pp

          generator = RetirementPlansReportPdfGenerator.new(pp)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        end

        def retirement_plans_xlsx
          pp = find_pay_period_for_report
          return unless pp

          send_spreadsheet!(
            filename: "retirement_plans_report_#{pp.start_date}_to_#{pp.end_date}.xlsx",
            sheets: retirement_plans_sheets(pp)
          )
        end

        # GET /api/v1/admin/reports/installment_loans_pdf
        def installment_loans_pdf
          company = Company.find(current_company_id)
          as_of = parse_optional_iso_date(params[:as_of_date], param_name: "as_of_date")
          return if performed?

          generator = InstallmentLoanReportPdfGenerator.new(company, as_of_date: as_of)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        end

        def installment_loans_xlsx
          company = Company.find(current_company_id)
          as_of = parse_optional_iso_date(params[:as_of_date], param_name: "as_of_date")
          return if performed?

          send_spreadsheet!(
            filename: "employee_installment_loans_#{as_of || Date.current}.xlsx",
            sheets: installment_loans_sheets(company, as_of_date: as_of)
          )
        end

        # GET /api/v1/admin/reports/transmittal_preview
        def transmittal_preview
          pp = find_pay_period_for_report
          return unless pp

          items = pp.payroll_items.not_voided.reportable
          saved = pp.transmittal
          live_check_numbers = items.where.not(check_number: nil).pluck(:check_number).map(&:to_s).sort_by { |number| [ number.match?(/\A\d+\z/) ? 0 : 1, number.to_i, number ] }
          check_numbers = saved&.payroll_check_numbers.nil? ? live_check_numbers : Array(saved&.payroll_check_numbers)
          ne_checks = pp.non_employee_checks.active.order(:id)

          total_fit  = items.sum(:withholding_tax)
          emp_ss     = items.sum(:social_security_tax)
          er_ss      = items.sum(:employer_social_security_tax)
          emp_med    = items.sum(:medicare_tax)
          er_med     = items.sum(:employer_medicare_tax)
          total_fica = emp_ss + er_ss + emp_med + er_med

          render json: {
            payroll_checks: {
              count: check_numbers.size,
              first: check_numbers.first,
              last: check_numbers.last,
              numbers: check_numbers,
              ranges: CheckNumberRangeFormatter.format(check_numbers)
            },
            non_employee_checks: ne_checks.map { |c|
              {
                id: c.id,
                check_number: c.check_number,
                payable_to: c.payable_to,
                amount: c.amount.to_f,
                check_type: c.check_type,
                memo: c.memo,
                description: c.description
              }
            },
            tax_totals: {
              fit: total_fit.to_f,
              employee_ss: emp_ss.to_f,
              employer_ss: er_ss.to_f,
              employee_medicare: emp_med.to_f,
              employer_medicare: er_med.to_f,
              total_fica: total_fica.to_f,
              total_drt_deposit: total_fit.to_f
            },
            saved_transmittal: saved ? {
              preparer_name: saved.preparer_name,
              notes: saved.notes,
              report_list: saved.report_list,
              transmittal_date: saved.transmittal_date&.iso8601,
              check_number_first: saved.check_number_first,
              check_number_last: saved.check_number_last,
              payroll_check_numbers: saved.payroll_check_numbers,
              non_employee_check_numbers: saved.non_employee_check_numbers,
              custom_entries: saved.custom_entries || [],
              generated_at: saved.generated_at&.iso8601,
              updated_by_id: saved.updated_by_id,
              created_at: saved.created_at.iso8601,
              updated_at: saved.updated_at.iso8601
            } : nil
          }
        end

        # GET /api/v1/admin/reports/transmittal_log_pdf
        def transmittal_log_pdf
          pp = find_pay_period_for_report
          return unless pp

          options = transmittal_options
          return if performed?

          options = resolve_transmittal_defaults(pp, options)
          save_transmittal_state!(pp, options)
          generator = TransmittalLogPdfGenerator.new(pp, options)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        end

        # GET /api/v1/admin/reports/full_print_package_pdf
        # Combines all reports for a pay period into a single PDF download
        def full_print_package_pdf
          pp = find_pay_period_for_report
          return unless pp

          pdf = CombinePDF.new
          company = pp.company
          t_options = transmittal_options
          return if performed?

          t_options = resolve_transmittal_defaults(pp, t_options)
          save_transmittal_state!(pp, t_options)

          generators = [
            TransmittalLogPdfGenerator.new(pp, t_options),
            PayrollSummaryByEmployeePdfGenerator.new(pp),
            DeductionsContributionsReportPdfGenerator.new(pp),
            PaycheckHistoryPdfGenerator.new(pp),
            RetirementPlansReportPdfGenerator.new(pp)
          ]

          # Add installment loans if company has any active loans
          if company.employee_loans.active.where(tracking_mode: "balance_tracked").any?
            generators << InstallmentLoanReportPdfGenerator.new(company, as_of_date: pp.pay_date)
          end

          generators.each do |gen|
            individual_pdf = CombinePDF.parse(gen.generate)
            pdf << individual_pdf
          end

          send_data pdf.to_pdf,
            filename: "print_package_#{pp.start_date}_to_#{pp.end_date}.pdf",
            type: "application/pdf",
            disposition: "attachment"
        rescue StandardError => e
          Rails.logger.error("[Reports] full_print_package_pdf failed for pay_period=#{pp&.id}: #{e.class}: #{e.message}")
          render json: { error: "Failed to generate full print package: #{e.message}" }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/reports/check_signoff_sheet
        def check_signoff_sheet
          pp = find_pay_period_for_report
          return unless pp

          custom_entries, notes = resolve_signoff_params(pp)
          save_signoff_state!(pp, custom_entries, notes) if params[:entries].present?

          generator = CheckSignoffSheetGenerator.new(pp, notes: notes, custom_entries: custom_entries)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            disposition: "attachment"
        end

        # POST /api/v1/admin/reports/check_signoff_pdf
        def check_signoff_pdf
          pp = find_pay_period_for_report
          return unless pp

          custom_entries, notes = resolve_signoff_params(pp)
          save_signoff_state!(pp, custom_entries, notes) if params[:entries].present?

          generator = CheckSignoffPdfGenerator.new(pp, notes: notes, custom_entries: custom_entries)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "inline"
        end

        # GET /api/v1/admin/reports/check_signoff_preview
        def check_signoff_preview
          pp = find_pay_period_for_report
          return unless pp

          saved = CheckSignoffSheet.find_by(pay_period_id: pp.id)

          items = pp.payroll_items
            .not_voided.reportable
            .joins("INNER JOIN employees ON employees.id = payroll_items.employee_id")
            .select("payroll_items.id, payroll_items.employee_id, payroll_items.check_number, employees.first_name, employees.last_name")
            .order("employees.last_name ASC, employees.first_name ASC")

          payroll_entries = items.map { |item|
            {
              id: item.id,
              employee_id: item.employee_id,
              name: "#{item.last_name}, #{item.first_name}",
              check_number: item.check_number.presence || ""
            }
          }

          render json: {
            company_name: pp.company.name,
            period_start: pp.start_date,
            period_end: pp.end_date,
            entries: payroll_entries,
            saved_signoff: saved ? {
              entries: saved.entries,
              notes: saved.notes,
              generated_at: saved.generated_at,
              updated_at: saved.updated_at
            } : nil
          }
        end

        # GET /api/v1/admin/reports/ytd_summary
        # Payroll summary for all employees. The legacy route name remains for
        # compatibility; callers may request either a calendar year or an exact
        # pay-date range.
        def ytd_summary
          render json: { report: build_period_summary_report(payroll_reporting_period) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def ytd_summary_xlsx
          period = payroll_reporting_period
          report = build_period_summary_report(period)

          send_spreadsheet!(
            filename: "#{report.dig(:meta, :provisional) ? 'test_only_' : ''}payroll_summary_#{period.filename_token}#{period_summary_visibility_suffix}.xlsx",
            sheets: ytd_summary_sheets(report)
          )
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def ytd_summary_pdf
          period = payroll_reporting_period
          report = build_period_summary_report(period)
          send_tabular_pdf!(
            title: report.dig(:meta, :provisional) ? "TEST ONLY — Payroll Summary by Pay Date" : "Payroll Summary by Pay Date",
            subtitle: "#{report.dig(:meta, :company_name)} — #{period.label}#{report.dig(:meta, :provisional) ? ' — calculated, not paid' : ''}",
            filename: "#{report.dig(:meta, :provisional) ? 'test_only_' : ''}payroll_summary_#{period.filename_token}#{period_summary_visibility_suffix}.pdf",
            sheets: ytd_summary_sheets(report).each_with_index.map do |sheet, index|
              index.zero? ? sheet.merge(pdf_frozen_columns: 3, pdf_max_columns: 9) : sheet
            end
          )
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def ytd_summary_csv
          period = payroll_reporting_period
          report = build_period_summary_report(period)
          send_tabular_csv!(
            filename: "#{report.dig(:meta, :provisional) ? 'test_only_' : ''}payroll_summary_#{period.filename_token}#{period_summary_visibility_suffix}.csv",
            sheet: ytd_summary_sheets(report).first
          )
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def annual_payroll_summary
          render json: { report: build_annual_payroll_summary }
        end

        def annual_payroll_summary_xlsx
          report = build_annual_payroll_summary
          send_spreadsheet!(
            filename: "annual_payroll_summary.xlsx",
            sheets: annual_payroll_summary_sheets(report)
          )
        end

        def annual_payroll_summary_pdf
          report = build_annual_payroll_summary
          send_tabular_pdf!(
            title: "Annual Payroll Totals",
            subtitle: "#{report.dig(:meta, :company_name)} — all available payroll years",
            filename: "annual_payroll_summary.pdf",
            sheets: annual_payroll_summary_pdf_sheets(report)
          )
        end

        def annual_payroll_summary_csv
          report = build_annual_payroll_summary
          send_tabular_csv!(
            filename: "annual_payroll_summary.csv",
            sheet: annual_payroll_summary_sheets(report).first
          )
        end

        private

        # Report routes use several target contracts, including pay_period_id
        # and pay_run_key. Builders retain the resolved target so document
        # access stays understandable without trusting a raw numeric :id.
        def audit_record
          return @audit_report_record if defined?(@audit_report_record)
          return if params[:pay_period_id].blank?

          PayPeriod.find_by(id: params[:pay_period_id], company_id: current_company_id)
        end

        def audit_record_metadata(record)
          return {} unless %w[document_access export].include?(audit_event_category)

          action_key = action_name.to_s
          format = {
            "application/pdf" => "PDF",
            "text/csv" => "CSV",
            "text/plain" => "TXT",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "XLSX"
          }[response.media_type]
          format ||= %w[pdf csv xlsx ascii].find { |candidate| action_key.end_with?("_#{candidate}") }&.upcase
          report_key = action_key.sub(/_(pdf|csv|xlsx|ascii)\z/, "").sub(/_preview\z/, "").sub(/_print\z/, "")
          disposition = response.headers["Content-Disposition"].to_s
          access_type = if disposition.match?(/attachment/i)
            "download"
          elsif action_key.include?("preview")
            "preview"
          else
            "view"
          end
          pay_period_id = record.id if record.is_a?(PayPeriod)
          target_key = @audit_report_target_key.presence || ("native:#{pay_period_id}" if pay_period_id)
          period_subject = @audit_report_period_subject.presence || AuditRecordSnapshot.subject_name(record)

          {
            report_key: report_key,
            report_format: format,
            access_type: access_type,
            report_target_key: target_key,
            report_period_subject: period_subject,
            pay_period_id: pay_period_id
          }.compact
        end

        def remember_audit_report_target!(report, record: nil)
          pay_period = report.fetch(:pay_period)
          @audit_report_record = record
          @audit_report_target_key = pay_period.fetch(:key)
          @audit_report_period_subject = [ pay_period[:start_date], pay_period[:end_date] ]
            .map { |date| date&.to_date&.strftime("%b %-d, %Y") }
            .compact
            .join(" – ")
        end

        YTD_SORT_FIELDS = %w[
          name employment_type status gross_pay withholding_tax social_security_tax
          medicare_tax retirement total_deductions custom_earnings_total custom_deductions_total net_pay
        ].freeze

        def filtered_ytd_employees
          employees = Employee.where(company_id: current_company_id)
                              .includes(:employee_ytd_totals)

          employees = employees.where(employment_type: params[:employment_type]) if params[:employment_type].present?
          employees = employees.where(status: params[:status]) if params[:status].present?

          if params[:search].present?
            query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search].to_s.strip)}%"
            employees = employees.where(
              "first_name ILIKE :query OR last_name ILIKE :query OR CONCAT(first_name, ' ', last_name) ILIKE :query",
              query: query
            )
          end

          employees.order(:last_name, :first_name)
        end

        def sort_ytd_rows(rows)
          sort_by = YTD_SORT_FIELDS.include?(params[:sort_by].to_s) ? params[:sort_by].to_s : "name"
          direction = params[:sort_direction].to_s == "desc" ? "desc" : "asc"

          sorted = rows.sort_by do |row|
            case sort_by
            when "name"
              [ row[:last_name].to_s.downcase, row[:first_name].to_s.downcase ]
            when "employment_type", "status"
              [ row[sort_by.to_sym].to_s.downcase, row[:last_name].to_s.downcase, row[:first_name].to_s.downcase ]
            else
              [ row[sort_by.to_sym].to_d, row[:last_name].to_s.downcase, row[:first_name].to_s.downcase ]
            end
          end

          direction == "desc" ? sorted.reverse : sorted
        end

        def include_zero_pay_employees?
          !params.key?(:include_zero_pay) || ActiveModel::Type::Boolean.new.cast(params[:include_zero_pay])
        end

        def period_summary_visibility_suffix
          include_zero_pay_employees? ? "" : "_exclude_zero_pay"
        end

        def active_zero_pay_employee?(row)
          row[:status] == "active" && row[:gross_pay].to_d.zero? && row[:net_pay].to_d.zero?
        end

        def transmittal_options
          opts = {}
          opts[:preparer_name] = params[:preparer_name] if params[:preparer_name].present?
          opts[:notes] = Array(params[:notes]) if params[:notes].present?
          opts[:report_list] = Array(params[:report_list]) if params.key?(:report_list)
          if params[:transmittal_date].present?
            opts[:transmittal_date] = parse_optional_iso_date(params[:transmittal_date], param_name: "transmittal_date")
            return opts if performed?
          end
          if params.key?(:payroll_check_numbers)
            opts[:payroll_check_numbers] = Array(params[:payroll_check_numbers]).map(&:to_s).map(&:strip).reject(&:blank?)
          end
          opts[:check_number_first] = params[:check_number_first] if params[:check_number_first].present?
          opts[:check_number_last] = params[:check_number_last] if params[:check_number_last].present?
          if params[:non_employee_check_numbers].present?
            opts[:non_employee_check_numbers] = params[:non_employee_check_numbers].to_unsafe_h.transform_keys(&:to_i)
          end
          if params[:custom_entries].present?
            opts[:custom_entries] = Array(params[:custom_entries]).map { |e| e.permit(:title, details: []).to_h }
          end
          opts
        end

        def resolve_transmittal_defaults(pay_period, options)
          transmittal = pay_period.transmittal
          options = options.dup
          options[:transmittal_date] = if options.key?(:transmittal_date)
            options[:transmittal_date]
          else
            transmittal&.transmittal_date || Date.current
          end
          options[:payroll_check_numbers] = if options.key?(:payroll_check_numbers)
            options[:payroll_check_numbers]
          else
            transmittal&.payroll_check_numbers.nil? ? pay_period.payroll_items.not_voided.reportable.where.not(check_number: nil).pluck(:check_number).map(&:to_s).sort_by { |number| [ number.match?(/\A\d+\z/) ? 0 : 1, number.to_i, number ] } : Array(transmittal.payroll_check_numbers)
          end
          options
        end

        def save_transmittal_state!(pay_period, options)
          transmittal = pay_period.transmittal || pay_period.build_transmittal(
            company_id: pay_period.company_id,
            created_by_id: current_user&.id
          )
          transmittal.assign_attributes(
            preparer_name: options[:preparer_name],
            transmittal_date: options.key?(:transmittal_date) ? options[:transmittal_date] : (transmittal.transmittal_date || Date.current),
            notes: options[:notes] || [],
            report_list: options.key?(:report_list) ? options[:report_list] : [],
            payroll_check_numbers: options.key?(:payroll_check_numbers) ? options[:payroll_check_numbers] : transmittal.payroll_check_numbers,
            check_number_first: options[:check_number_first],
            check_number_last: options[:check_number_last],
            non_employee_check_numbers: options[:non_employee_check_numbers] || {},
            custom_entries: options[:custom_entries] || [],
            generated_at: Time.current,
            updated_by_id: current_user&.id
          )
          transmittal.save!
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          Rails.logger.warn("[Transmittal] Failed to save state for pay_period=#{pay_period.id}: #{e.message}")
        end

        def resolve_signoff_params(pay_period)
          if params[:entries].present?
            entries = Array(params[:entries]).map { |e| e.permit(:name, :check_number).to_h }
            notes = params[:notes].present? ? Array(params[:notes]) : []
          else
            saved = CheckSignoffSheet.find_by(pay_period_id: pay_period.id)
            if saved
              entries = saved.entries.map { |e| e.stringify_keys }
              notes = saved.notes || []
            else
              entries = nil
              notes = []
            end
          end
          [ entries, notes ]
        end

        def save_signoff_state!(pay_period, entries, notes)
          sheet = CheckSignoffSheet.find_or_initialize_by(pay_period_id: pay_period.id)
          sheet.assign_attributes(
            company_id: pay_period.company_id,
            entries: entries || [],
            notes: notes || [],
            generated_at: Time.current,
            updated_by_id: current_user&.id
          )
          sheet.save!
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          Rails.logger.warn("[CheckSignoffSheet] Failed to save state for pay_period=#{pay_period.id}: #{e.message}")
        end

        def find_pay_period_for_report
          pay_period_id = params[:pay_period_id]
          if pay_period_id.blank?
            render json: { error: "pay_period_id is required" }, status: :unprocessable_entity
            return nil
          end

          pp = PayPeriod.find_by(id: pay_period_id)
          unless pp && pp.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found
            return nil
          end

          pp
        end

        # Shared data builder for payroll register (JSON + CSV + PDF).
        # Returns [report_data, nil] on success or [nil, rendered_response] on error.
        # pay_run_key accepts native:<id> or imported:<id>. pay_period_id remains
        # supported for older native-payroll clients.
        def build_payroll_register_data(raw_key_override = nil)
          raw_key = raw_key_override.presence || params[:pay_run_key].presence
          raw_key ||= "native:#{params[:pay_period_id]}" if params[:pay_period_id].present?

          if raw_key.blank?
            return [ nil, render(json: { error: "pay_period_id is required" }, status: :unprocessable_entity) ]
          end

          match = raw_key.to_s.match(/\A(native|imported):(\d+)\z/)
          unless match
            return [ nil, render(json: { error: "pay_run_key must use native:<id> or imported:<id>" }, status: :unprocessable_entity) ]
          end

          source_type = match[1]
          record_id = match[2].to_i
          if source_type == "imported"
            report = ImportedPayrollRegister.new(
              company_id: current_company_id,
              historical_pay_period_id: record_id
            ).call
            remember_audit_report_target!(report)
            return [ report, nil ]
          end

          pay_period = PayPeriod.find_by(id: record_id, company_id: current_company_id)

          # Calculated and approved periods remain available from the pay-period
          # review screen, but drafts and voided runs cannot be exported as a
          # payroll register even when someone supplies a native key directly.
          unless pay_period && !pay_period.draft? && !pay_period.voided?
            return [ nil, render(json: { error: "Pay period not found" }, status: :not_found) ]
          end

          @audit_report_record = pay_period
          @audit_report_target_key = "native:#{pay_period.id}"
          @audit_report_period_subject = AuditRecordSnapshot.subject_name(pay_period)

          items = sorted_payroll_items(
            pay_period.payroll_items.not_voided.reportable.includes(
              :payroll_item_earnings,
              { payroll_item_field_entries: :payroll_field_definition },
              { payroll_item_deductions: :deduction_type, employee: :department }
            )
          )
          w2_items = items.reject { |i| i.employment_type == "contractor" }
          contractor_items = items.select { |i| i.employment_type == "contractor" }

          company = pay_period.company
          intake_tip_components = company.simple_payroll_register_enabled? ? intake_tip_components_by_item_id(items) : {}
          lifecycle = pay_period_lifecycle_report(pay_period)
          adjustment_disclosure = PayrollAdjustmentDisclosure.new(items)
          report_data = {
            type: "payroll_register",
            simple_payroll_register_enabled: company.simple_payroll_register_enabled?,
            meta: report_meta(company, :payroll_register),
            source: {
              system: "cornerstone",
              label: company.test_workspace? ? "Cornerstone test payroll" : "Cornerstone",
              locked: pay_period.committed?,
              statement: company.test_workspace? ?
                "TEST ONLY — calculated rehearsal payroll, not committed or paid. Values may change if recalculated." :
                "This payroll was calculated in Cornerstone. Committed payroll is an immutable payroll record."
            },
            pay_period: {
              key: "native:#{pay_period.id}",
              id: pay_period.id,
              record_type: "native",
              start_date: pay_period.start_date,
              end_date: pay_period.end_date,
              pay_date: pay_period.pay_date,
              status: pay_period.status
            },
            lifecycle: lifecycle,
            summary: {
              employee_count: w2_items.size,
              contractor_count: contractor_items.size,
              total_hours: w2_items.sum { |item| item.hours_worked.to_f },
              total_overtime_hours: w2_items.sum { |item| item.overtime_hours.to_f },
              total_gross: w2_items.sum(&:gross_pay),
              total_reported_tips: w2_items.sum(&:reported_tips),
              total_tips_paid_out: w2_items.sum(&:tips_paid_out),
              total_bonus: w2_items.sum(&:bonus),
              total_non_taxable_pay: w2_items.sum(&:non_taxable_pay),
              total_custom_earnings: w2_items.sum { |item| custom_earnings_total(item) },
              total_custom_deductions: w2_items.sum { |item| custom_deductions_total(item) },
              total_payroll_adjustment_taxable_additions: w2_items.sum(&:taxable_payroll_adjustments_total),
              total_payroll_adjustment_non_taxable_additions: w2_items.sum(&:non_taxable_payroll_adjustments_total),
              total_payroll_adjustment_pre_tax_deductions: w2_items.sum(&:pre_tax_payroll_adjustments_total),
              total_payroll_adjustment_post_tax_deductions: w2_items.sum(&:post_tax_payroll_adjustments_total),
              total_payroll_field_taxable_additions: w2_items.sum { |item| payroll_field_total(item, "taxable_addition") },
              total_payroll_field_non_taxable_additions: w2_items.sum { |item| payroll_field_total(item, "non_taxable_addition") },
              total_payroll_field_pre_tax_deductions: w2_items.sum { |item| payroll_field_total(item, "pre_tax_deduction") },
              total_payroll_field_post_tax_deductions: w2_items.sum { |item| payroll_field_total(item, "post_tax_deduction") },
              total_payroll_field_employer_contributions: w2_items.sum { |item| payroll_field_total(item, "employer_contribution") },
              total_withholding: w2_items.sum(&:withholding_tax),
              total_additional_withholding: w2_items.sum(&:additional_withholding),
              total_social_security: w2_items.sum(&:social_security_tax),
              total_medicare: w2_items.sum(&:medicare_tax),
              total_employer_social_security: w2_items.sum(&:employer_social_security_tax),
              total_employer_medicare: w2_items.sum(&:employer_medicare_tax),
              total_traditional_retirement: w2_items.sum(&:retirement_payment),
              total_roth_retirement: w2_items.sum(&:roth_retirement_payment),
              total_retirement: w2_items.sum(&:retirement_payment).to_f + w2_items.sum(&:roth_retirement_payment).to_f,
              total_employer_traditional_retirement: w2_items.sum(&:employer_retirement_match),
              total_employer_roth_retirement: w2_items.sum(&:employer_roth_retirement_match),
              total_employer_retirement: w2_items.sum(&:employer_retirement_match).to_f + w2_items.sum(&:employer_roth_retirement_match).to_f,
              total_straight_loan_deductions: money(w2_items.sum(BigDecimal("0")) { |item| straight_loan_amount(item) }),
              total_installment_loan_payments: money(w2_items.sum(BigDecimal("0")) { |item| installment_loan_amount(item) }),
              total_loan_payments: money(w2_items.sum(BigDecimal("0")) { |item| straight_loan_amount(item) + installment_loan_amount(item) }),
              total_employer_contributions: w2_items.sum { |item| employer_contributions_total(item) },
              total_employer_payroll_cost: w2_items.sum { |item| employer_payroll_cost(item) },
              total_deductions: w2_items.sum(&:total_deductions),
              total_net: w2_items.sum(&:net_pay),
              contractor_total_gross: contractor_items.sum(&:gross_pay),
              contractor_total_net: contractor_items.sum(&:net_pay)
            },
            payroll_adjustments: {
              totals: adjustment_disclosure.totals,
              entries: adjustment_disclosure.rows,
              treatment_totals: adjustment_disclosure.treatment_totals
            },
            employees: w2_items.map { |item| payroll_item_detail(item, fallback_tip_components: intake_tip_components[item.id]) },
            contractors: contractor_items.map { |item| payroll_item_detail(item, fallback_tip_components: intake_tip_components[item.id]) }
          }
          if report_data[:simple_payroll_register_enabled]
            report_data[:simple_register] = simple_payroll_register_payload(report_data)
          end

          [ report_data, nil ]
        rescue ActiveRecord::RecordNotFound
          [ nil, render(json: { error: "Pay period not found" }, status: :not_found) ]
        end

        # Shared data builder for tax summary (JSON + CSV + PDF).
        # Returns [report_data, nil] on success or [nil, rendered_response] on error.
        # year defaults to current year; quarter is optional (1-4). Exact
        # start_date/end_date parameters override the calendar selectors.
        def build_tax_summary_data
          year    = params[:year]&.to_i || Date.current.year
          quarter = params[:quarter].present? ? params[:quarter].to_i : nil

          if quarter && !(1..4).cover?(quarter)
            return [ nil, render(json: { error: "quarter must be 1, 2, 3, or 4" }, status: :unprocessable_entity) ]
          end

          period = if params[:start_date].present? || params[:end_date].present?
            payroll_reporting_period
          elsif quarter
            start_month = ((quarter - 1) * 3) + 1
            end_month   = start_month + 2
            start_date  = Date.new(year, start_month, 1)
            end_date    = Date.new(year, end_month, -1)
            PayrollReportingPeriod.new(start_date: start_date, end_date: end_date)
          else
            PayrollReportingPeriod.from_params(params, default_year: year)
          end

          pay_periods = reportable_pay_periods(period)

          items                   = reportable_payroll_items(period).where.not(employment_type: "contractor")
          item_rows               = items.to_a
          field_disclosure        = PayrollFieldDisclosure.new(item_rows)
          employee_ss_total       = item_rows.sum { |item| item.social_security_tax.to_f }
          employee_medicare_total = item_rows.sum { |item| item.medicare_tax.to_f }
          employer_ss_total       = item_rows.sum { |item| item.employer_social_security_tax.to_f }
          employer_medicare_total = item_rows.sum { |item| item.employer_medicare_tax.to_f }
          withholding_total       = item_rows.sum { |item| item.withholding_tax.to_f }

          company = Company.find(current_company_id)
          report_data = {
            type: "tax_summary",
            meta: report_meta(company, :tax_summary),
            period: period.payload.merge(
              year: period.year || year,
              quarter: params[:start_date].present? ? nil : quarter,
              custom: params[:start_date].present?,
              label: quarter ? "Q#{quarter} #{year}" : period.label
            ),
            totals: {
              gross_wages:               item_rows.sum { |item| item.gross_pay.to_f },
              withholding_tax:           withholding_total,
              social_security_employee:  employee_ss_total,
              social_security_employer:  employer_ss_total,
              medicare_employee:         employee_medicare_total,
              medicare_employer:         employer_medicare_total,
              total_employment_taxes:    employee_ss_total + employer_ss_total + employee_medicare_total + employer_medicare_total + withholding_total
            },
            payroll_fields: {
              totals: field_disclosure.totals,
              treatment_totals: field_disclosure.treatment_totals
            },
            pay_periods_included: pay_periods.count,
            employee_count:       item_rows.map(&:employee_id).uniq.length
          }

          [ report_data, nil ]
        rescue ArgumentError => e
          [ nil, render(json: { error: e.message }, status: :unprocessable_entity) ]
        end

        def build_quarterly_compliance_packet_data
          raw_year = params[:year]
          year = raw_year.present? ? Integer(raw_year, exception: false) : Date.current.year
          quarter = params[:quarter]&.to_i

          unless year && year > 2000 && year <= Date.current.year + 1
            return [ nil, render(json: { error: "year must be a valid 4-digit tax year" }, status: :unprocessable_entity) ]
          end

          unless quarter && (1..4).cover?(quarter)
            return [ nil, render(json: { error: "quarter is required and must be 1, 2, 3, or 4" }, status: :unprocessable_entity) ]
          end

          company = Company.find(current_company_id)
          report = QuarterlyCompliancePacketBuilder.new(company, year, quarter).generate
          report[:filing_gate] = PayrollFilingResponsibilityGate.quarterly(
            company: company,
            tax_year: year,
            quarter: quarter
          )
          [ report, nil ]
        rescue ActiveRecord::RecordNotFound
          [ nil, render(json: { error: "Company not found" }, status: :not_found) ]
        rescue HistoricalPayrollFilingSource::BridgeValidationError => e
          [ nil, render(
            json: {
              error: e.message,
              error_code: e.code,
              historical_import_batch_ids: e.historical_import_batch_ids,
              recovery_path: "/historical-payroll"
            },
            status: :unprocessable_entity
          ) ]
        rescue ArgumentError => e
          [ nil, render(json: { error: e.message }, status: :unprocessable_entity) ]
        end

        def quarterly_compliance_task_params
          params.require(:task).permit(
            :status,
            :due_date,
            :internal_target_date,
            :notes,
            data: {}
          )
        end

        def quarterly_compliance_packet_context
          raw_year = params[:year]
          year = raw_year.present? ? Integer(raw_year, exception: false) : Date.current.year
          quarter = params[:quarter]&.to_i

          unless year && year > 2000 && year <= Date.current.year + 1
            return [ nil, nil, nil, render(json: { error: "year must be a valid 4-digit tax year" }, status: :unprocessable_entity) ]
          end

          unless quarter && (1..4).cover?(quarter)
            return [ nil, nil, nil, render(json: { error: "quarter is required and must be 1, 2, 3, or 4" }, status: :unprocessable_entity) ]
          end

          [ year, quarter, Company.find(current_company_id), nil ]
        end

        def send_quarterly_compliance_official_form!(generator:, filename_prefix:)
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          send_data generator.new(report: report_data).generate,
            filename: "#{filename_prefix}_#{report_data.dig(:meta, :year)}_q#{report_data.dig(:meta, :quarter)}.pdf",
            type: "application/pdf",
            disposition: "attachment"
        rescue OfficialPdfOverlay::TemplateUnavailableError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def send_quarterly_compliance_official_form_from_params!(disposition:)
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          config = quarterly_compliance_official_form_config(params[:form_type])
          if disposition == "attachment"
            filing_type = PayrollFilingResponsibilityGate::OFFICIAL_FORM_FILING_TYPES.fetch(params[:form_type].to_s)
            filing_gate = report_data.dig(:filing_gate, :filings, filing_type)
            unless filing_gate.dig(:capabilities, :can_export_filing_ready)
              return render json: {
                error: "Resolve payroll filing responsibility before downloading an official filing output",
                filing_gate: filing_gate
              }, status: :unprocessable_entity
            end
          end
          fields = quarterly_compliance_official_form_fields(params[:form_type])
          send_data config.fetch(:generator).new(report: report_data, fields: fields).generate,
            filename: "#{config.fetch(:filename_prefix)}_#{report_data.dig(:meta, :year)}_q#{report_data.dig(:meta, :quarter)}.pdf",
            type: "application/pdf",
            disposition: disposition
        rescue OfficialPdfOverlay::TemplateUnavailableError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def quarterly_compliance_official_form_config(form_type)
          {
            "form_941" => { generator: QuarterlyComplianceOfficialForms::Form941, filename_prefix: "federal_form_941_draft" },
            "schedule_b" => { generator: QuarterlyComplianceOfficialForms::ScheduleB, filename_prefix: "federal_form_941_schedule_b_draft" },
            "w1" => { generator: QuarterlyComplianceOfficialForms::W1, filename_prefix: "guam_w1_draft" },
            "swica" => { generator: QuarterlyComplianceOfficialForms::Sw2, filename_prefix: "guam_sw2_draft" }
          }.fetch(form_type.to_s) { raise ArgumentError, "form_type must be form_941, schedule_b, w1, or swica" }
        end

        def quarterly_compliance_official_form_fields(form_type)
          raw_fields = params[:fields]
          return {} if raw_fields.blank?
          raise ArgumentError, "fields must be an object" unless raw_fields.respond_to?(:permit)

          fields = case form_type.to_s
          when "form_941"
            raw_fields.permit(*OFFICIAL_FORM_COMPANY_FIELDS, lines: OFFICIAL_FORM_941_LINE_FIELDS).to_h
          when "schedule_b"
            raw_fields.permit(*OFFICIAL_FORM_COMPANY_FIELDS, daily_liabilities: [ :pay_date, :amount ]).to_h
          when "w1"
            raw_fields.permit(*OFFICIAL_FORM_COMPANY_FIELDS, :total_guam_withholding, daily_liabilities: [ :pay_date, :amount ]).to_h
          when "swica"
            raw_fields.permit(
              *OFFICIAL_FORM_COMPANY_FIELDS,
              employees: [
                :employee_id, :name, :ssn_last_four, :status, :termination_date,
                :gross_pay, :net_pay, :deductions, :swica_wages, :reported_tips,
                :non_taxable_pay, :guam_withholding, :social_security_tax,
                :employer_social_security_tax, :medicare_tax, :employer_medicare_tax,
                :federal_941_liability, :social_security_wages, :social_security_tips,
                :medicare_wages_tips, { pay_dates: [] }
              ]
            ).to_h
          else
            raise ArgumentError, "form_type must be form_941, schedule_b, w1, or swica"
          end

          validate_official_form_fields!(fields)
          validate_official_form_row_limits!(fields)
          fields
        end

        def validate_official_form_fields!(value)
          case value
          when Hash
            value.each_value { |child| validate_official_form_fields!(child) }
          when Array
            value.each { |child| validate_official_form_fields!(child) }
          when String
            raise ArgumentError, "fields contain a value longer than #{OFFICIAL_FORM_STRING_LIMIT} characters" if value.length > OFFICIAL_FORM_STRING_LIMIT
          when Numeric, NilClass, TrueClass, FalseClass
            true
          else
            raise ArgumentError, "fields contain an unsupported value type"
          end
        end

        def validate_official_form_row_limits!(fields)
          daily_count = Array(fields["daily_liabilities"]).length
          if daily_count > OFFICIAL_FORM_DAILY_LIABILITY_LIMIT
            raise ArgumentError, "daily_liabilities cannot include more than #{OFFICIAL_FORM_DAILY_LIABILITY_LIMIT} rows"
          end

          employee_count = Array(fields["employees"]).length
          if employee_count > OFFICIAL_FORM_SWICA_EMPLOYEE_LIMIT
            raise ArgumentError, "employees cannot include more than #{OFFICIAL_FORM_SWICA_EMPLOYEE_LIMIT} rows"
          end
        end

        def quarterly_compliance_official_form_defaults(report, form_type)
          case form_type.to_s
          when "form_941"
            {
              form_type: "form_941",
              title: "Federal Form 941",
              **quarterly_compliance_company_fields(report),
              lines: report.dig(:federal_941, :report, :lines)
            }
          when "schedule_b"
            {
              form_type: "schedule_b",
              title: "Federal Form 941 Schedule B",
              **quarterly_compliance_company_fields(report),
              daily_liabilities: Array(report[:pay_periods]).group_by { |period| period[:pay_date] }.map do |pay_date, periods|
                {
                  pay_date: pay_date,
                  amount: periods.sum { |period| period[:federal_941_liability].to_f }
                }
              end.sort_by { |row| row[:pay_date] }
            }
          when "w1"
            {
              form_type: "w1",
              title: "Guam W-1",
              **quarterly_compliance_company_fields(report),
              daily_liabilities: report.dig(:w1, :daily_liabilities),
              total_guam_withholding: report.dig(:w1, :total_guam_withholding)
            }
          when "swica"
            {
              form_type: "swica",
              title: "Guam SW-2",
              **quarterly_compliance_company_fields(report),
              employees: report.dig(:swica, :employees)
            }
          else
            raise ArgumentError, "form_type must be form_941, schedule_b, w1, or swica"
          end
        end

        def quarterly_compliance_company_fields(report)
          {
            company_name: report.dig(:meta, :company_name),
            ein: report.dig(:meta, :ein),
            company_address: report.dig(:federal_941, :report, :employer_info, :address),
            company_address_line1: report.dig(:meta, :company_address_line1),
            company_address_line2: report.dig(:meta, :company_address_line2),
            company_city: report.dig(:meta, :company_city),
            company_state: report.dig(:meta, :company_state),
            company_zip: report.dig(:meta, :company_zip)
          }
        end

        # Shared year validation + aggregation for W-2GU exports (CSV/PDF).
        # Returns [report_data, nil] on success or [nil, rendered_response] on error.
        def build_w2_gu_report_data
          raw_year = params[:year]
          year = if raw_year.present?
            Integer(raw_year, exception: false)
          else
            Date.current.year
          end

          unless year && year > 2000 && year <= Date.current.year + 1
            return [ nil, render(json: { error: "year must be a valid 4-digit tax year" }, status: :unprocessable_entity) ]
          end

          company     = Company.find(current_company_id)
          report_data = W2GuAggregator.new(company, year).generate
          report_data[:filing_gate] = PayrollFilingResponsibilityGate.annual(company: company, tax_year: year)
          [ report_data, nil ]
        end

        def current_pay_period_summary
          pp = PayPeriod.where(company_id: current_company_id)
                       .where(status: %w[draft calculated approved])
                       .order(pay_date: :desc)
                       .first

          return nil unless pp

          {
            id: pp.id,
            period_description: pp.period_description,
            pay_date: pp.pay_date,
            status: pp.status,
            employee_count: pp.payroll_items.not_voided.reportable.count,
            total_gross: pp.payroll_items.not_voided.reportable.sum(:gross_pay),
            total_net: pp.payroll_items.not_voided.reportable.sum(:net_pay)
          }
        end

        def payroll_reporting_period
          PayrollReportingPeriod.from_params(params)
        end

        def employee_pay_history_period
          return PayrollReportingPeriod.all_time if ActiveModel::Type::Boolean.new.cast(params[:all_time])

          payroll_reporting_period
        end

        def reportable_pay_periods(period, pay_run: nil)
          scope = PayPeriod.reportable_for_company(current_company)
                           .where(pay_date: period.range)
          return scope unless pay_run
          return scope.none if pay_run.fetch(:record_type) == "imported"

          scope.where(id: pay_run.fetch(:id))
        end

        def reportable_payroll_items(period, pay_run: nil)
          PayrollItem.joins(:pay_period)
                     .includes(:employee, :pay_period, { payroll_item_field_entries: :payroll_field_definition }, payroll_item_deductions: :deduction_type)
                     .not_voided.reportable
                     .where(pay_periods: { id: reportable_pay_periods(period, pay_run: pay_run).select(:id) })
        end

        def employee_pay_history_items(employee, period)
          scope = employee.payroll_items
                          .joins(:pay_period)
                          .includes(:pay_period, :payroll_item_field_entries, :check_events, :direct_deposit_payment_confirmation)
                          .not_voided.reportable
                          .where(pay_periods: { id: reportable_pay_periods(period).select(:id) })
                          .order("pay_periods.pay_date DESC, payroll_items.id DESC")
          scope
        end

        def build_period_summary_report(period)
          pay_run = selected_summary_pay_run(period)
          employees = filtered_ytd_employees
          items = reportable_payroll_items(period, pay_run: pay_run).to_a
          items_by_employee = items.group_by(&:employee_id)
          unified = UnifiedPayrollReporting.new(company_id: current_company_id, period: period)
          historical_paychecks = filter_summary_historical_records(unified.historical_paychecks, pay_run)
          historical_by_employee = historical_paychecks.group_by(&:employee_id)
          historical_adjustments = filter_summary_historical_adjustments(unified.historical_adjustments, pay_run)
          adjustments_by_employee = historical_adjustments.group_by { |adjustment| adjustment.historical_paycheck.employee_id }
          disclosure = PayrollFieldDisclosure.new(items)
          adjustment_disclosure = PayrollAdjustmentDisclosure.new(items)
          historical_deductions = unified.historical_deduction_entries(historical_paychecks, historical_adjustments)
          employee_rows = sort_ytd_rows(employees.map do |employee|
            payroll_period_employee_row(
              employee,
              items_by_employee[employee.id] || [],
              historical_by_employee[employee.id] || [],
              adjustments_by_employee[employee.id] || [],
              unified: unified
            )
          end)
          zero_pay_count = employee_rows.count { |row| active_zero_pay_employee?(row) }
          employee_rows.reject! { |row| active_zero_pay_employee?(row) } unless include_zero_pay_employees?
          visible_employee_ids = employee_rows.map { |row| row[:employee_id] }
          component_columns = period_summary_component_columns(
            disclosure.rows + adjustment_disclosure.rows + historical_deductions,
            visible_employee_ids
          )
          employee_rows.each do |row|
            row[:component_values] = period_summary_component_values(component_columns, row[:employee_id])
          end

          {
            type: "ytd_summary",
            meta: report_meta(Company.find(current_company_id), :ytd_summary),
            year: period.year,
            period: period.payload,
            included_payroll_runs: included_payroll_runs(period, historical_paychecks, pay_run: pay_run),
            employees: employee_rows,
            employee_visibility: {
              include_zero_pay: include_zero_pay_employees?,
              active_zero_pay_count: zero_pay_count,
              displayed_count: employee_rows.length
            },
            component_columns: component_columns.map { |column| column.except(:entries) },
            historical_deductions: {
              source_bucket_totals: historical_deductions.group_by { |entry| [ entry[:source], entry[:treatment] ] }.map do |(source, treatment), entries|
                { source: source, treatment: treatment, amount: entries.sum(BigDecimal("0")) { |entry| entry[:amount] } }
              end,
              classification_note: "QuickBooks deduction labels retain their source tax buckets. Historical loan labels do not establish straight versus installment treatment. A 401(k) After Tax label in a QuickBooks pre-tax bucket is shown separately, not reclassified."
            },
            company_totals: payroll_period_company_totals(
              items, period, historical_paychecks, historical_adjustments, unified: unified
            ),
            source_summary: unified.source_summary(
              native_items: items,
              historical_paychecks: historical_paychecks,
              historical_adjustments: historical_adjustments,
              excluded_unlinked_paychecks: filter_summary_historical_records(unified.unlinked_historical_paychecks, pay_run)
            ),
            payroll_fields: {
              totals: disclosure.totals,
              entries: disclosure.rows.select { |entry| visible_employee_ids.include?(entry[:employee_id]) },
              treatment_totals: disclosure.treatment_totals
            },
            payroll_adjustments: {
              totals: adjustment_disclosure.totals,
              entries: adjustment_disclosure.rows.select { |entry| visible_employee_ids.include?(entry[:employee_id]) },
              treatment_totals: adjustment_disclosure.treatment_totals
            }
          }
        end

        def included_payroll_runs(period, historical_paychecks, pay_run: nil)
          native = reportable_pay_periods(period, pay_run: pay_run).order(:pay_date, :start_date, :id).map do |pay_period|
            {
              key: "native:#{pay_period.id}", source: "Cornerstone", status: pay_period.status,
              work_period_start: pay_period.start_date, work_period_end: pay_period.end_date, pay_date: pay_period.pay_date
            }
          end
          imported = historical_paychecks
            .map(&:historical_pay_period)
            .select { |historical_period| historical_period.period_type == "regular" }
            .uniq(&:id)
            .map do |historical_period|
              {
                key: "imported:#{historical_period.id}", source: "QuickBooks import", status: "locked",
                work_period_start: historical_period.start_date, work_period_end: historical_period.end_date, pay_date: historical_period.pay_date
              }
            end

          (native + imported).sort_by { |pay_run| [ pay_run[:pay_date], pay_run[:work_period_start], pay_run[:key] ] }
        end

        def selected_summary_pay_run(period)
          raw_key = params[:pay_run_key].presence
          return nil unless raw_key

          match = raw_key.to_s.match(/\A(native|imported):(\d+)\z/)
          raise ArgumentError, "pay_run_key must use native:<id> or imported:<id>" unless match

          record_type = match[1]
          record_id = match[2].to_i
          pay_date = if record_type == "native"
            PayPeriod.reportable_for_company(current_company).where(id: record_id).pick(:pay_date)
          else
            HistoricalPayPeriod
              .joins(:historical_import_batch)
              .where(id: record_id, company_id: current_company_id, period_type: "regular")
              .where(historical_import_batches: { company_id: current_company_id, status: "locked" })
              .pick(:pay_date)
          end
          raise ArgumentError, "Pay run not found" unless pay_date && period.range.cover?(pay_date)

          { key: raw_key.to_s, record_type: record_type, id: record_id }
        end

        def filter_summary_historical_records(records, pay_run)
          return records unless pay_run
          return [] if pay_run.fetch(:record_type) == "native"

          records.select { |record| record.historical_pay_period_id == pay_run.fetch(:id) }
        end

        def filter_summary_historical_adjustments(adjustments, pay_run)
          return adjustments unless pay_run
          return [] if pay_run.fetch(:record_type) == "native"

          adjustments.select do |adjustment|
            adjustment.historical_paycheck.historical_pay_period_id == pay_run.fetch(:id)
          end
        end

        def period_summary_component_columns(entries, employee_ids)
          entries.select { |entry| employee_ids.include?(entry[:employee_id]) }
            .group_by do |entry|
              if entry.key?(:historical_source) || entry[:source].in?(%w[quickbooks historical_adjustment])
                "historical:#{entry[:source]}:#{entry[:treatment]}:#{entry[:label]}"
              elsif entry.key?(:tax_treatment)
                entry[:payroll_field_definition_id] ? "field:definition:#{entry[:payroll_field_definition_id]}" : "field:entry:#{entry[:payroll_item_field_entry_id]}"
              else
                "adjustment:item:#{entry[:payroll_item_id]}:#{entry[:position]}"
              end
            end
            .map do |key, grouped|
              first = grouped.first
              historical = first[:source].in?(%w[quickbooks historical_adjustment])
              field = first.key?(:tax_treatment)
              treatment = field ? first[:tax_treatment] : first[:treatment]
              identity = if historical
                first[:source] == "quickbooks" ? "QuickBooks source" : "Historical adjustment"
              elsif field
                first[:payroll_field_definition_id] ? "field ##{first[:payroll_field_definition_id]}" : "entry ##{first[:payroll_item_field_entry_id]}"
              else
                "#{first[:employee_name]}, item ##{first[:payroll_item_id]}/#{first[:position].to_i + 1}"
              end
              source_group = if first[:source] == "quickbooks"
                "quickbooks_history"
              elsif first[:source] == "historical_adjustment"
                "historical_adjustment"
              elsif field
                "cornerstone_field"
              else
                "cornerstone_adjustment"
              end
              {
                key: key,
                label: "#{historical ? identity : (field ? 'Payroll Field' : 'Payroll Adjustment')} - #{first[:label]} (#{treatment.to_s.humanize}; #{identity})",
                short_label: first[:label],
                identity_label: identity,
                source_group: source_group,
                treatment: treatment,
                entries: grouped
              }
            end
            .sort_by { |column| [ column[:source_group], column[:treatment].to_s, column[:short_label].to_s, column[:key] ] }
        end

        def period_summary_component_values(columns, employee_id)
          columns.each_with_object({}) do |column, values|
            matches = column[:entries].select { |entry| entry[:employee_id] == employee_id }
            values[column[:key]] = matches.sum(BigDecimal("0")) do |entry|
              BigDecimal(entry[:amount].to_s.presence || "0")
            end if matches.any?
          end
        end

        def payroll_period_employee_row(employee, items, historical_paychecks = [], historical_adjustments = [], unified: nil)
          custom_totals = custom_ytd_totals_for_items(items)
          treatment_totals = PayrollFieldDisclosure.new(items).treatment_totals
          retirement_totals = payroll_summary_retirement_totals(items)
          employer_cost_totals = payroll_summary_employer_cost_totals(items)

          row = {
            employee_id: employee.id,
            first_name: employee.first_name,
            last_name: employee.last_name,
            name: employee.full_name,
            employment_type: employee.employment_type,
            status: employee.status,
            payroll_count: items.map(&:pay_period_id).uniq.length,
            imported_payroll_count: 0,
            imported_opening_summary_count: 0,
            gross_pay: items.sum { |item| item.gross_pay.to_f },
            total_hours: items.sum { |item| item.hours_worked.to_f },
            total_overtime_hours: items.sum { |item| item.overtime_hours.to_f },
            custom_earnings_total: custom_totals[:custom_earnings_total],
            payroll_field_taxable_additions_total: treatment_totals["taxable_addition"],
            payroll_field_non_taxable_additions_total: treatment_totals["non_taxable_addition"],
            payroll_field_pre_tax_deductions_total: treatment_totals["pre_tax_deduction"],
            payroll_field_post_tax_deductions_total: treatment_totals["post_tax_deduction"],
            health_insurance_deductions: PayrollFieldDisclosure.new(items).rows.select { |entry| entry[:label].to_s.match?(/\AHealth Insurance\z/i) && entry[:employee_paid] }.sum(BigDecimal("0")) { |entry| entry[:amount] },
            payroll_field_employer_contributions_total: treatment_totals["employer_contribution"],
            withholding_tax: items.sum { |item| item.withholding_tax.to_f },
            social_security_tax: items.sum { |item| item.social_security_tax.to_f },
            medicare_tax: items.sum { |item| item.medicare_tax.to_f },
            retirement: retirement_totals[:retirement].to_f,
            roth_retirement: retirement_totals[:roth_retirement].to_f,
            tips: items.sum { |item| item.reported_tips.to_f },
            tips_paid_out: items.sum { |item| item.tips_paid_out.to_f },
            bonus: items.sum { |item| payroll_summary_bonus_amount(item).to_f },
            straight_loan_deductions: money(items.sum(BigDecimal("0")) { |item| straight_loan_amount(item) }),
            installment_loan_payments: money(items.sum(BigDecimal("0")) { |item| installment_loan_amount(item) }),
            historical_loan_deductions_unclassified: 0,
            source_labeled_after_tax_401k_in_pretax_bucket: 0,
            **employer_cost_totals,
            total_deductions: custom_totals[:total_deductions],
            custom_deductions_total: custom_totals[:custom_deductions_total],
            net_pay: items.sum { |item| item.net_pay.to_f }
          }
          return row if historical_paychecks.empty? && historical_adjustments.empty?

          (unified || UnifiedPayrollReporting.new(company_id: current_company_id, period: payroll_reporting_period))
            .add_historical_to_employee_row(row, historical_paychecks, historical_adjustments)
        end

        def payroll_period_company_totals(items, period, historical_paychecks = [], historical_adjustments = [], unified: nil)
          treatment_totals = PayrollFieldDisclosure.new(items).treatment_totals
          retirement_totals = payroll_summary_retirement_totals(items)
          employer_cost_totals = payroll_summary_employer_cost_totals(items)

          row = {
            year: period.year,
            start_date: period.start_date,
            end_date: period.end_date,
            period_basis: "pay_date",
            gross_pay: items.sum { |item| item.gross_pay.to_f },
            total_hours: items.sum { |item| item.hours_worked.to_f },
            total_overtime_hours: items.sum { |item| item.overtime_hours.to_f },
            bonus: items.sum { |item| payroll_summary_bonus_amount(item).to_f },
            straight_loan_deductions: money(items.sum(BigDecimal("0")) { |item| straight_loan_amount(item) }),
            installment_loan_payments: money(items.sum(BigDecimal("0")) { |item| installment_loan_amount(item) }),
            historical_loan_deductions_unclassified: 0,
            source_labeled_after_tax_401k_in_pretax_bucket: 0,
            **employer_cost_totals,
            custom_earnings_total: items.sum { |item| custom_earnings_total(item) },
            payroll_field_taxable_additions_total: treatment_totals["taxable_addition"],
            payroll_field_non_taxable_additions_total: treatment_totals["non_taxable_addition"],
            payroll_field_pre_tax_deductions_total: treatment_totals["pre_tax_deduction"],
            payroll_field_post_tax_deductions_total: treatment_totals["post_tax_deduction"],
            health_insurance_deductions: PayrollFieldDisclosure.new(items).rows.select { |entry| entry[:label].to_s.match?(/\AHealth Insurance\z/i) && entry[:employee_paid] }.sum(BigDecimal("0")) { |entry| entry[:amount] },
            payroll_field_employer_contributions_total: treatment_totals["employer_contribution"],
            withholding_tax: items.sum { |item| item.withholding_tax.to_f },
            social_security_tax: items.sum { |item| item.social_security_tax.to_f },
            medicare_tax: items.sum { |item| item.medicare_tax.to_f },
            retirement: retirement_totals[:retirement].to_f,
            roth_retirement: retirement_totals[:roth_retirement].to_f,
            total_deductions: items.sum { |item| item.total_deductions.to_f },
            custom_deductions_total: items.sum { |item| custom_deductions_total(item) },
            net_pay: items.sum { |item| item.net_pay.to_f },
            payroll_count: items.map(&:pay_period_id).uniq.length,
            employee_count: items.map(&:employee_id).uniq.length,
            imported_payroll_count: 0,
            imported_opening_summary_count: 0
          }
          return row if historical_paychecks.empty? && historical_adjustments.empty?

          (unified || UnifiedPayrollReporting.new(company_id: current_company_id, period: period))
            .add_historical_to_company_totals(
              row,
              historical_paychecks,
              historical_adjustments,
              native_employee_ids: items.map(&:employee_id)
            )
        end

        def ytd_company_totals(year = Date.current.year)
          period = PayrollReportingPeriod.new(
            start_date: Date.new(year, 1, 1),
            end_date: Date.new(year, 12, 31),
            year: year
          )
          items = reportable_payroll_items(period).to_a
          unified = UnifiedPayrollReporting.new(company_id: current_company_id, period: period)
          historical_paychecks = unified.historical_paychecks
          historical_adjustments = unified.historical_adjustments

          payroll_period_company_totals(
            items,
            period,
            historical_paychecks,
            historical_adjustments,
            unified: unified
          )
        end

        def recent_payroll_summary
          rows = %w[cornerstone quickbooks].flat_map do |source|
            PayrollHistoryQuery.new(
              company_id: current_company_id,
              params: {
                page: 1,
                per_page: 5,
                source: source,
                status: source == "cornerstone" ? "committed" : "locked",
                sort: "pay_date",
                direction: "desc"
              }
            ).call.data
          end

          rows.sort_by { |row| [ row.fetch(:pay_date).to_date, row.fetch(:key) ] }
              .reverse
              .first(5)
              .map do |row|
            row.slice(:key, :record_type, :id, :pay_date, :employee_count, :total_net, :source).merge(
              period_description: payroll_history_period_description(row)
            )
          end
        end

        def payroll_history_period_description(row)
          start_date = row.fetch(:start_date).to_date
          end_date = row.fetch(:end_date).to_date

          "#{start_date.strftime('%b %-d, %Y')} - #{end_date.strftime('%b %-d, %Y')}"
        end

        def payroll_item_detail(item, fallback_tip_components: nil)
          {
            employee_id: item.employee_id,
            employee_first_name: item.employee&.first_name,
            employee_last_name: item.employee&.last_name,
            employee_name: item.employee.full_name,
            department_name: item.employee&.department&.name,
            employment_type: item.employment_type,
            worker_classification: employment_type_label(item.employment_type),
            pay_rate: item.pay_rate,
            scheduled_hours: item.scheduled_hours&.to_f,
            hours_worked: item.hours_worked&.to_f,
            overtime_hours: item.overtime_hours&.to_f,
            holiday_hours: item.holiday_hours&.to_f,
            pto_hours: item.pto_hours&.to_f,
            reported_tips: item.reported_tips.to_f,
            tips_paid_out: item.tips_paid_out.to_f,
            bonus: item.bonus.to_f,
            non_taxable_pay: item.non_taxable_pay,
            total_additions: item.total_additions,
            custom_earnings: item.custom_earnings || [],
            custom_earnings_total: custom_earnings_total(item),
            custom_deductions: item.custom_deductions || [],
            custom_deductions_total: custom_deductions_total(item),
            payroll_adjustments: payroll_adjustment_rows(item),
            payroll_adjustment_totals: payroll_adjustment_totals(item),
            payroll_adjustment_taxable_additions_total: item.taxable_payroll_adjustments_total,
            payroll_adjustment_non_taxable_additions_total: item.non_taxable_payroll_adjustments_total,
            payroll_adjustment_pre_tax_deductions_total: item.pre_tax_payroll_adjustments_total,
            payroll_adjustment_post_tax_deductions_total: item.post_tax_payroll_adjustments_total,
            payroll_field_entries: payroll_field_entry_rows(item),
            payroll_field_totals: payroll_field_totals(item),
            payroll_field_taxable_additions_total: payroll_field_total(item, "taxable_addition"),
            payroll_field_non_taxable_additions_total: payroll_field_total(item, "non_taxable_addition"),
            payroll_field_pre_tax_deductions_total: payroll_field_total(item, "pre_tax_deduction"),
            payroll_field_post_tax_deductions_total: payroll_field_total(item, "post_tax_deduction"),
            payroll_field_employer_contributions_total: payroll_field_total(item, "employer_contribution"),
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            additional_withholding: item.additional_withholding.to_f,
            additional_withholding_override: item.additional_withholding_override,
            withholding_tax_adjustment: item.withholding_tax_adjustment.to_f,
            withholding_tax_override: item.withholding_tax_override,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            employer_social_security_tax: item.employer_social_security_tax,
            employer_medicare_tax: item.employer_medicare_tax,
            retirement_payment: item.retirement_payment.to_f,
            roth_retirement_payment: item.roth_retirement_payment.to_f,
            total_retirement_payment: item.retirement_payment.to_f + item.roth_retirement_payment.to_f,
            employer_retirement_match: item.employer_retirement_match.to_f,
            employer_roth_retirement_match: item.employer_roth_retirement_match.to_f,
            total_employer_retirement_match: item.employer_retirement_match.to_f + item.employer_roth_retirement_match.to_f,
            loan_deduction: item.loan_deduction.to_f,
            loan_payment: item.loan_payment.to_f,
            straight_loan_deduction: money(straight_loan_amount(item)),
            installment_loan_payment: money(installment_loan_amount(item)),
            employer_contributions_total: employer_contributions_total(item),
            employer_payroll_cost: employer_payroll_cost(item),
            insurance_payment: item.insurance_payment.to_f,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            check_number: item.check_number,
            check_date: item.check_date,
            tip_components: tip_component_rows(item, fallback_components: fallback_tip_components),
            earnings_breakdown: item.payroll_item_earnings.map { |earning| earning_row(earning) },
            deductions_breakdown: deductions_breakdown(item),
            employer_contributions_breakdown: employer_contributions_breakdown(item)
          }
        end

        def pay_history_item(item)
          {
            key: "native:#{item.id}",
            record_type: "native",
            payroll_item_id: item.id,
            pay_period_id: item.pay_period_id,
            historical_pay_period_id: nil,
            pay_date: item.pay_period.pay_date,
            period_description: item.pay_period.period_description,
            scheduled_hours: item.scheduled_hours&.to_f,
            hours_worked: item.hours_worked&.to_f,
            overtime_hours: item.overtime_hours&.to_f,
            holiday_hours: item.holiday_hours&.to_f,
            pto_hours: item.pto_hours&.to_f,
            reported_tips: item.reported_tips.to_f,
            tips_paid_out: item.tips_paid_out.to_f,
            bonus: item.bonus.to_f,
            custom_earnings_total: custom_earnings_total(item),
            custom_deductions_total: custom_deductions_total(item),
            gross_pay: item.gross_pay.to_f,
            withholding_tax: item.withholding_tax.to_f,
            social_security_tax: item.social_security_tax.to_f,
            medicare_tax: item.medicare_tax.to_f,
            total_deductions: item.total_deductions.to_f,
            net_pay: item.net_pay.to_f,
            check_number: item.check_number,
            payment_delivery_method: item.effective_payment_delivery_method,
            payment_method_label: PayrollPaymentLabel.for(item),
