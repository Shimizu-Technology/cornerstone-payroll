# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ReportsController < BaseController
        REPORT_DESCRIPTIONS = {
          payroll_register: "Full payroll detail for the selected pay period, including hours, earnings, taxes, deductions, employer taxes, net pay, and check numbers.",
          payroll_summary_by_employee: "Employee-by-employee payroll summary for the selected pay period, including earnings, deductions, taxes, employer contributions, and total payroll cost.",
          deductions_contributions: "Detailed employee deductions and employer contribution activity for the selected pay period.",
          paycheck_history: "Check numbers, check dates, earnings, deductions, and net pay for payroll items in the selected pay period.",
          retirement_plans: "401(k), Roth 401(k), and employer retirement contribution activity for the selected pay period.",
          tax_summary: "Payroll tax withholding summary used to review Guam/federal payroll tax liability for the selected year or quarter.",
          ytd_summary: "Year-to-date payroll totals by worker for the selected tax year.",
          employee_pay_history: "Paycheck history for an individual worker, including recent pay periods and year-to-date totals.",
          form_941_gu: "Federal Form 941 preparation worksheet for Guam employers, with Guam-specific line 2/3 skip handling and FICA liability detail.",
          quarterly_compliance_packet: "Quarterly Guam and federal payroll filing packet covering Form 500, W-1, SWICA, Federal Form 941, and review tie-outs.",
          w2_gu: "W-2GU preparation workbook for W-2 employees for the selected tax year.",
          form_1099_nec: "1099-NEC preparation workbook for contractor compensation and filing readiness.",
          installment_loans: "Employee installment loan balances and transaction history as of the selected date."
        }.freeze

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

          items = employee.payroll_items
                         .includes(:pay_period)
                         .not_voided
                         .where(pay_periods: {
                           id: PayPeriod.reportable_committed
                                        .where(company_id: employee.company_id)
                                        .select(:id)
                         })
                         .order("pay_periods.pay_date DESC")
                         .limit(params[:limit] || 12)

          render json: {
            report: employee_pay_history_report(employee, items)
          }
        end

        def employee_pay_history_xlsx
          employee = Employee.find(params[:employee_id])

          unless employee.company_id == current_company_id
            return render json: { error: "Employee not found" }, status: :not_found
          end

          items = employee.payroll_items
                         .includes(:pay_period)
                         .not_voided
                         .where(pay_periods: {
                           id: PayPeriod.reportable_committed
                                        .where(company_id: employee.company_id)
                                        .select(:id)
                         })
                         .order("pay_periods.pay_date DESC")
                         .limit(params[:limit] || 12)

          send_spreadsheet!(
            filename: "employee_pay_history_#{employee.last_name}_#{employee.first_name}.xlsx",
            sheets: employee_pay_history_sheets(employee_pay_history_report(employee, items))
          )
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

        def quarterly_compliance_packet
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          render json: { report: report_data }
        end

        def quarterly_compliance_packet_xlsx
          report_data, error_response = build_quarterly_compliance_packet_data
          return error_response if error_response

          send_spreadsheet!(
            filename: "quarterly_compliance_packet_#{report_data.dig(:meta, :year)}_q#{report_data.dig(:meta, :quarter)}.xlsx",
            sheets: quarterly_compliance_packet_sheets(report_data)
          )
        end

        def quarterly_compliance_packet_form_941_pdf
          send_quarterly_compliance_official_form!(
            generator: QuarterlyComplianceOfficialForms::Form941,
            filename_prefix: "federal_form_941"
          )
        end

        def quarterly_compliance_packet_schedule_b_pdf
          send_quarterly_compliance_official_form!(
            generator: QuarterlyComplianceOfficialForms::ScheduleB,
            filename_prefix: "federal_form_941_schedule_b"
          )
        end

        def quarterly_compliance_packet_w1_pdf
          send_quarterly_compliance_official_form!(
            generator: QuarterlyComplianceOfficialForms::W1,
            filename_prefix: "guam_w1"
          )
        end

        def quarterly_compliance_packet_swica_pdf
          send_quarterly_compliance_official_form!(
            generator: QuarterlyComplianceOfficialForms::Sw2,
            filename_prefix: "guam_sw2"
          )
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
            filing: filing_readiness_payload(filing)
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

          filing = W2FilingReadiness.find_by(company_id: current_company_id, year: year)
          render json: { filing: filing ? filing_readiness_payload(filing) : nil }
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

          if filing.status == "filing_ready"
            return render json: { filing: filing_readiness_payload(filing) }
          end

          company = Company.find(current_company_id)
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
            revalidation: revalidation_payload(fresh_preflight)
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
            sheets: payroll_summary_by_employee_sheets(report_data)
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

          items = pp.payroll_items.not_voided
          check_numbers = items.where.not(check_number: nil).pluck(:check_number).sort_by(&:to_i)
          ne_checks = pp.non_employee_checks.active.order(:id)

          total_fit  = items.sum(:withholding_tax)
          emp_ss     = items.sum(:social_security_tax)
          er_ss      = items.sum(:employer_social_security_tax)
          emp_med    = items.sum(:medicare_tax)
          er_med     = items.sum(:employer_medicare_tax)
          total_fica = emp_ss + er_ss + emp_med + er_med

          saved = pp.transmittal

          render json: {
            payroll_checks: {
              count: check_numbers.size,
              first: check_numbers.first,
              last: check_numbers.last
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
              check_number_first: saved.check_number_first,
              check_number_last: saved.check_number_last,
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
          save_transmittal_state!(pp, t_options)

          generators = [
            TransmittalLogPdfGenerator.new(pp, t_options),
            PayrollSummaryByEmployeePdfGenerator.new(pp),
            DeductionsContributionsReportPdfGenerator.new(pp),
            PaycheckHistoryPdfGenerator.new(pp),
            RetirementPlansReportPdfGenerator.new(pp)
          ]

          # Add installment loans if company has any active loans
          if company.employee_loans.active.any?
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
            .not_voided
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
        # Year-to-date summary for all employees
        def ytd_summary
          year = params[:year]&.to_i || Date.current.year

          employees = filtered_ytd_employees
          custom_totals_by_employee = ytd_custom_totals_by_employee(year)

          render json: {
            report: {
              type: "ytd_summary",
              meta: report_meta(Company.find(current_company_id), :ytd_summary),
              year: year,
              employees: sort_ytd_rows(employees.map { |emp| employee_ytd_row(emp, year, custom_totals_by_employee[emp.id]) }),
              company_totals: ytd_company_totals(year)
            }
          }
        end

        def ytd_summary_xlsx
          year = params[:year]&.to_i || Date.current.year
          employees = filtered_ytd_employees
          custom_totals_by_employee = ytd_custom_totals_by_employee(year)
          report = {
            type: "ytd_summary",
            meta: report_meta(Company.find(current_company_id), :ytd_summary),
            year: year,
            employees: sort_ytd_rows(employees.map { |emp| employee_ytd_row(emp, year, custom_totals_by_employee[emp.id]) }),
            company_totals: ytd_company_totals(year)
          }

          send_spreadsheet!(
            filename: "ytd_summary_#{year}.xlsx",
            sheets: ytd_summary_sheets(report)
          )
        end

        private

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
              query:
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

        def transmittal_options
          opts = {}
          opts[:preparer_name] = params[:preparer_name] if params[:preparer_name].present?
          opts[:notes] = Array(params[:notes]) if params[:notes].present?
          opts[:report_list] = Array(params[:report_list]) if params.key?(:report_list)
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

        def save_transmittal_state!(pay_period, options)
          transmittal = pay_period.transmittal || pay_period.build_transmittal(
            company_id: pay_period.company_id,
            created_by_id: current_user&.id
          )
          transmittal.assign_attributes(
            preparer_name: options[:preparer_name],
            notes: options[:notes] || [],
            report_list: options.key?(:report_list) ? options[:report_list] : [],
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
        # pay_period_id param is required.
        def build_payroll_register_data
          pay_period_id = params[:pay_period_id]

          if pay_period_id.blank?
            return [ nil, render(json: { error: "pay_period_id is required" }, status: :unprocessable_entity) ]
          end

          pay_period = PayPeriod.includes(payroll_items: [ :payroll_item_earnings, { payroll_item_deductions: :deduction_type, employee: :department } ]).find_by(id: pay_period_id)

          unless pay_period && pay_period.company_id == current_company_id
            return [ nil, render(json: { error: "Pay period not found" }, status: :not_found) ]
          end

          items = sorted_payroll_items(pay_period.payroll_items.not_voided)
          w2_items = items.reject { |i| i.employment_type == "contractor" }
          contractor_items = items.select { |i| i.employment_type == "contractor" }

          company = pay_period.company
          report_data = {
            type: "payroll_register",
            meta: report_meta(company, :payroll_register),
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
              total_reported_tips: w2_items.sum(&:reported_tips),
              total_tips_paid_out: w2_items.sum(&:tips_paid_out),
              total_bonus: w2_items.sum(&:bonus),
              total_non_taxable_pay: w2_items.sum(&:non_taxable_pay),
              total_custom_earnings: w2_items.sum { |item| custom_earnings_total(item) },
              total_custom_deductions: w2_items.sum { |item| custom_deductions_total(item) },
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
              total_loan_payments: w2_items.sum(&:loan_payment),
              total_deductions: w2_items.sum(&:total_deductions),
              total_net: w2_items.sum(&:net_pay),
              contractor_total_gross: contractor_items.sum(&:gross_pay),
              contractor_total_net: contractor_items.sum(&:net_pay)
            },
            employees: w2_items.map { |item| payroll_item_detail(item) },
            contractors: contractor_items.map { |item| payroll_item_detail(item) }
          }

          [ report_data, nil ]
        end

        # Shared data builder for tax summary (JSON + CSV + PDF).
        # Returns [report_data, nil] on success or [nil, rendered_response] on error.
        # year defaults to current year; quarter is optional (1-4).
        def build_tax_summary_data
          year    = params[:year]&.to_i || Date.current.year
          quarter = params[:quarter].present? ? params[:quarter].to_i : nil

          if quarter && !(1..4).cover?(quarter)
            return [ nil, render(json: { error: "quarter must be 1, 2, 3, or 4" }, status: :unprocessable_entity) ]
          end

          # Get committed pay periods in range
          pay_periods = PayPeriod.reportable_committed
                                 .where(company_id: current_company_id)
                                 .for_year(year)

          if quarter
            start_month = ((quarter - 1) * 3) + 1
            end_month   = start_month + 2
            start_date  = Date.new(year, start_month, 1)
            end_date    = Date.new(year, end_month, -1)
            pay_periods = pay_periods.where(pay_date: start_date..end_date)
          end

          items                   = PayrollItem.joins(:pay_period).where(pay_periods: { id: pay_periods.pluck(:id) }).not_voided.where.not(employment_type: "contractor")
          employee_ss_total       = items.sum(:social_security_tax)
          employee_medicare_total = items.sum(:medicare_tax)
          employer_ss_total       = items.sum(:employer_social_security_tax)
          employer_medicare_total = items.sum(:employer_medicare_tax)
          withholding_total       = items.sum(:withholding_tax)

          company = Company.find(current_company_id)
          report_data = {
            type: "tax_summary",
            meta: report_meta(company, :tax_summary),
            period: {
              year:       year,
              quarter:    quarter,
              start_date: pay_periods.minimum("pay_periods.pay_date"),
              end_date:   pay_periods.maximum("pay_periods.pay_date")
            },
            totals: {
              gross_wages:               items.sum(:gross_pay),
              withholding_tax:           withholding_total,
              social_security_employee:  employee_ss_total,
              social_security_employer:  employer_ss_total,
              medicare_employee:         employee_medicare_total,
              medicare_employer:         employer_medicare_total,
              total_employment_taxes:    employee_ss_total + employer_ss_total + employee_medicare_total + employer_medicare_total + withholding_total
            },
            pay_periods_included: pay_periods.count,
            employee_count:       items.distinct.count(:employee_id)
          }

          [ report_data, nil ]
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
          [ QuarterlyCompliancePacketBuilder.new(company, year, quarter).generate, nil ]
        rescue ActiveRecord::RecordNotFound
          [ nil, render(json: { error: "Company not found" }, status: :not_found) ]
        rescue ArgumentError => e
          [ nil, render(json: { error: e.message }, status: :unprocessable_entity) ]
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
            employee_count: pp.payroll_items.not_voided.count,
            total_gross: pp.payroll_items.not_voided.sum(:gross_pay),
            total_net: pp.payroll_items.not_voided.sum(:net_pay)
          }
        end

        def ytd_company_totals(year = Date.current.year)
          reportable_period_ids = PayPeriod.reportable_committed
                                           .where(company_id: current_company_id)
                                           .where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
                                           .select(:id)

          items = PayrollItem.joins(:pay_period)
                            .where(company_id: current_company_id)
                            .not_voided
                            .where(pay_periods: {
                              id: reportable_period_ids
                            })

          ytd_items = items.to_a

          {
            year: year,
            gross_pay: items.sum(:gross_pay),
            custom_earnings_total: ytd_items.sum { |item| custom_earnings_total(item) },
            withholding_tax: items.sum(:withholding_tax),
            social_security_tax: items.sum(:social_security_tax),
            medicare_tax: items.sum(:medicare_tax),
            retirement: items.sum(:retirement_payment),
            total_deductions: items.sum(:total_deductions),
            custom_deductions_total: ytd_items.sum { |item| custom_deductions_total(item) },
            net_pay: items.sum(:net_pay),
            payroll_count: items.select("DISTINCT pay_period_id").count
          }
        end

        def recent_payroll_summary
          PayPeriod.reportable_committed
                   .where(company_id: current_company_id)
                   .order(pay_date: :desc)
                   .limit(5)
                   .map do |pp|
            {
              id: pp.id,
              period_description: pp.period_description,
              pay_date: pp.pay_date,
              employee_count: pp.payroll_items.not_voided.count,
              total_net: pp.payroll_items.not_voided.sum(:net_pay)
            }
          end
        end

        def payroll_item_detail(item)
          {
            employee_id: item.employee_id,
            employee_first_name: item.employee&.first_name,
            employee_last_name: item.employee&.last_name,
            employee_name: item.employee.full_name,
            department_name: item.employee&.department&.name,
            employment_type: item.employment_type,
            worker_classification: employment_type_label(item.employment_type),
            pay_rate: item.pay_rate,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            holiday_hours: item.holiday_hours,
            pto_hours: item.pto_hours,
            reported_tips: item.reported_tips,
            tips_paid_out: item.tips_paid_out,
            bonus: item.bonus,
            non_taxable_pay: item.non_taxable_pay,
            total_additions: item.total_additions,
            custom_earnings: item.custom_earnings || [],
            custom_earnings_total: custom_earnings_total(item),
            custom_deductions: item.custom_deductions || [],
            custom_deductions_total: custom_deductions_total(item),
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
            insurance_payment: item.insurance_payment.to_f,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            check_number: item.check_number,
            check_date: item.check_date,
            earnings_breakdown: item.payroll_item_earnings.map { |earning| earning_row(earning) },
            deductions_breakdown: deductions_breakdown(item)
          }
        end

        def pay_history_item(item)
          {
            pay_period_id: item.pay_period_id,
            pay_date: item.pay_period.pay_date,
            period_description: item.pay_period.period_description,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            holiday_hours: item.holiday_hours,
            pto_hours: item.pto_hours,
            reported_tips: item.reported_tips,
            tips_paid_out: item.tips_paid_out,
            bonus: item.bonus,
            custom_earnings_total: custom_earnings_total(item),
            custom_deductions_total: custom_deductions_total(item),
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            check_number: item.check_number
          }
        end

        def employee_ytd_summary(employee, year = Date.current.year)
          ytd_items = employee_reportable_ytd_items(employee, year)
          {
            year: year,
            gross_pay: ytd_items.sum { |item| item.gross_pay.to_f },
            custom_earnings_total: ytd_items.sum { |item| custom_earnings_total(item) },
            withholding_tax: ytd_items.sum { |item| item.withholding_tax.to_f },
            social_security_tax: ytd_items.sum { |item| item.social_security_tax.to_f },
            medicare_tax: ytd_items.sum { |item| item.medicare_tax.to_f },
            retirement: ytd_items.sum { |item| item.retirement_payment.to_f },
            roth_retirement: ytd_items.sum { |item| item.roth_retirement_payment.to_f },
            tips: ytd_items.sum { |item| item.reported_tips.to_f },
            tips_paid_out: ytd_items.sum { |item| item.tips_paid_out.to_f },
            bonus: ytd_items.sum { |item| item.bonus.to_f },
            total_deductions: ytd_items.sum { |item| item.total_deductions.to_f },
            custom_deductions_total: ytd_items.sum { |item| custom_deductions_total(item) },
            net_pay: ytd_items.sum { |item| item.net_pay.to_f }
          }
        end

        def employee_ytd_row(employee, year, custom_totals = nil)
          ytd_items = employee_reportable_ytd_items(employee, year)
          custom_totals ||= custom_ytd_totals_for_items(ytd_items)

          {
            employee_id: employee.id,
            first_name: employee.first_name,
            last_name: employee.last_name,
            name: employee.full_name,
            employment_type: employee.employment_type,
            status: employee.status,
            gross_pay: ytd_items.sum { |item| item.gross_pay.to_f },
            custom_earnings_total: custom_totals[:custom_earnings_total],
            withholding_tax: ytd_items.sum { |item| item.withholding_tax.to_f },
            social_security_tax: ytd_items.sum { |item| item.social_security_tax.to_f },
            medicare_tax: ytd_items.sum { |item| item.medicare_tax.to_f },
            retirement: ytd_items.sum { |item| item.retirement_payment.to_f },
            roth_retirement: ytd_items.sum { |item| item.roth_retirement_payment.to_f },
            tips: ytd_items.sum { |item| item.reported_tips.to_f },
            tips_paid_out: ytd_items.sum { |item| item.tips_paid_out.to_f },
            bonus: ytd_items.sum { |item| item.bonus.to_f },
            total_deductions: custom_totals[:total_deductions],
            custom_deductions_total: custom_totals[:custom_deductions_total],
            net_pay: ytd_items.sum { |item| item.net_pay.to_f }
          }
        end

        def employee_pay_history_report(employee, items)
          {
            type: "employee_pay_history",
            meta: report_meta(employee.company, :employee_pay_history),
            employee: {
              id: employee.id,
              name: employee.full_name,
              first_name: employee.first_name,
              last_name: employee.last_name,
              employment_type: employee.employment_type,
              pay_rate: employee.pay_rate
            },
            history: items.map { |item| pay_history_item(item) },
            ytd: employee_ytd_summary(employee)
          }
        end

        def sorted_payroll_items(items)
          items.to_a.sort_by do |item|
            [
              item.employee&.last_name.to_s.downcase,
              item.employee&.first_name.to_s.downcase,
              item.employee_id.to_i
            ]
          end
        end

        def build_pay_period_payroll_items_report(pay_period)
          items = sorted_payroll_items(
            pay_period.payroll_items.not_voided.includes(
              :payroll_item_earnings,
              payroll_item_deductions: :deduction_type,
              employee: :department
            )
          )
          w2_items = items.reject { |i| i.employment_type == "contractor" }
          contractor_items = items.select { |i| i.employment_type == "contractor" }
          {
            type: "payroll_summary_by_employee",
            meta: report_meta(pay_period.company, :payroll_summary_by_employee),
            pay_period: {
              id: pay_period.id,
              start_date: pay_period.start_date,
              end_date: pay_period.end_date,
              pay_date: pay_period.pay_date,
              status: pay_period.status
            },
            summary: {
              employee_count: w2_items.size,
              total_gross: w2_items.sum(&:gross_pay),
              total_reported_tips: w2_items.sum(&:reported_tips),
              total_tips_paid_out: w2_items.sum(&:tips_paid_out),
              total_bonus: w2_items.sum(&:bonus),
              total_custom_earnings: w2_items.sum { |item| custom_earnings_total(item) },
              total_custom_deductions: w2_items.sum { |item| custom_deductions_total(item) },
              total_withholding: w2_items.sum(&:withholding_tax),
              total_social_security: w2_items.sum(&:social_security_tax),
              total_medicare: w2_items.sum(&:medicare_tax),
              total_traditional_retirement: w2_items.sum(&:retirement_payment),
              total_roth_retirement: w2_items.sum(&:roth_retirement_payment),
              total_retirement: w2_items.sum(&:retirement_payment).to_f + w2_items.sum(&:roth_retirement_payment).to_f,
              total_employer_traditional_retirement: w2_items.sum(&:employer_retirement_match),
              total_employer_roth_retirement: w2_items.sum(&:employer_roth_retirement_match),
              total_employer_retirement: w2_items.sum(&:employer_retirement_match).to_f + w2_items.sum(&:employer_roth_retirement_match).to_f,
              total_deductions: w2_items.sum(&:total_deductions),
              total_net: w2_items.sum(&:net_pay)
            },
            employees: w2_items.map { |item| payroll_item_detail(item) },
            contractors: contractor_items.map { |item| payroll_item_detail(item) }
          }
        end

        def custom_earnings_total(item)
          Array(item.custom_earnings).sum { |entry| entry["amount"].to_f }
        end

        def custom_deductions_total(item)
          Array(item.custom_deductions).sum { |entry| entry["amount"].to_f }
        end

        def employee_reportable_ytd_items(employee, year)
          reportable_period_ids = PayPeriod.reportable_committed
                                           .where(company_id: current_company_id)
                                           .where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
                                           .select(:id)

          employee.payroll_items
                  .joins(:pay_period)
                  .where(company_id: current_company_id)
                  .not_voided
                  .where(pay_periods: { id: reportable_period_ids })
                  .to_a
        end

        def ytd_custom_totals_by_employee(year)
          reportable_period_ids = PayPeriod.reportable_committed
                                           .where(company_id: current_company_id)
                                           .where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
                                           .select(:id)

          PayrollItem.joins(:pay_period)
                     .where(company_id: current_company_id)
                     .not_voided
                     .where(pay_periods: { id: reportable_period_ids })
                     .select(:employee_id, :total_deductions, :custom_earnings, :custom_deductions)
                     .to_a
                     .group_by(&:employee_id)
                     .transform_values { |items| custom_ytd_totals_for_items(items) }
        end

        def custom_ytd_totals_for_items(items)
          {
            custom_earnings_total: items.sum { |item| custom_earnings_total(item) },
            custom_deductions_total: items.sum { |item| custom_deductions_total(item) },
            total_deductions: items.sum { |item| item.total_deductions.to_f }
          }
        end

        def earning_row(earning)
          {
            category: earning.category,
            label: earning.label,
            hours: earning.hours,
            rate: earning.rate,
            amount: earning.amount
          }
        end

        def deduction_row(deduction)
          {
            category: deduction.category,
            label: deduction.label,
            deduction_type: deduction.deduction_type&.name,
            amount: deduction.amount
          }
        end

        def custom_deduction_row(deduction)
          {
            category: "post_tax",
            label: deduction["label"].presence || "Other Deduction",
            deduction_type: "One-time deduction",
            amount: deduction["amount"].to_f
          }
        end

        def deductions_breakdown(item)
          item.payroll_item_deductions.map { |deduction| deduction_row(deduction) } +
            Array(item.custom_deductions).filter_map do |deduction|
              amount = deduction["amount"].to_f
              amount.positive? ? custom_deduction_row(deduction) : nil
            end
        end

        def send_spreadsheet!(filename:, sheets:)
          exporter = SpreadsheetReportExporter.new(filename: filename, sheets: sheets)
          send_data exporter.generate,
            filename: exporter.filename,
            type: SpreadsheetReportExporter::CONTENT_TYPE,
            disposition: "attachment"
        end

        def report_meta(company, report_key)
          {
            company_id: company&.id,
            company_name: company&.name,
            generated_at: Time.current.iso8601,
            report_description: REPORT_DESCRIPTIONS.fetch(report_key, nil)
          }
        end

        def report_info_sheet(report, title:, description: nil)
          meta = report_value(report, :meta) || {}
          pp = report_value(report, :pay_period) || {}
          rows = [
            [ "Field", "Value" ],
            [ "Report", title ],
            [ "Client", report_value(meta, :company_name) || report_value(report, :company, :name) || report_value(report, :employer, :name) || report_value(report, :payer, :name) ],
            [ "Description", description || report_value(meta, :report_description) ],
            [ "Pay Period", [ report_value(pp, :start_date), report_value(pp, :end_date) ].compact.join(" to ") ],
            [ "Pay Date", report_value(pp, :pay_date) ],
            [ "Generated At", report_value(meta, :generated_at) ]
          ].reject { |_, value| value.blank? }

          { name: "Report Info", rows: rows }
        end

        def report_value(hash, *keys)
          keys.reduce(hash) do |current, key|
            break nil unless current.respond_to?(:[])

            current[key] || current[key.to_s]
          end
        end

        def employment_type_label(type)
          case type.to_s
          when "salary"
            "W-2 Salary"
          when "hourly"
            "W-2 Hourly"
          when "contractor"
            "1099 Contractor"
          else
            type.to_s.titleize
          end
        end

        PAYROLL_REGISTER_HEADERS = [
          "Last Name", "First Name", "Employee Name", "Department", "Type", "Pay Rate",
          "Regular Hours", "Overtime Hours", "Holiday Hours", "PTO Hours",
          "Reported Tips", "Tips Paid Out", "Bonus", "Custom Earnings", "Non-Taxable Pay",
          "Gross Pay", "FIT", "Additional W/H", "SS Tax", "Medicare Tax",
          "Employer SS", "Employer Medicare", "401(k)", "Roth 401(k)",
          "Employer Match", "Employer Roth Match", "Loan Deduction", "Loan Payment",
          "Insurance", "Custom Deductions", "Total Deductions", "Net Pay", "Check Number", "Check Date"
        ].freeze

        def payroll_register_sheets(report)
          employee_rows = Array(report[:employees]).map { |emp| payroll_export_row(emp) }
          contractor_rows = Array(report[:contractors]).map { |emp| payroll_export_row(emp) }
          sheets = [
            { name: "Employees", rows: [ PAYROLL_REGISTER_HEADERS ] + employee_rows }
          ]
          sheets << { name: "Contractors", rows: [ PAYROLL_REGISTER_HEADERS ] + contractor_rows } if contractor_rows.any?
          sheets << earnings_breakdown_sheet(report)
          sheets << deductions_breakdown_sheet(report)
          sheets << report_info_sheet(report, title: "Payroll Register")
          sheets
        end

        PAYROLL_SUMMARY_BY_EMPLOYEE_HEADERS = [
          "Last Name", "First Name", "Employee Name", "Type", "Gross Pay",
          "Reported Tips", "Tips Paid Out", "Bonus", "Custom Earnings",
          "FIT", "SS Tax", "Medicare Tax", "401(k)", "Roth 401(k)",
          "Loan Deduction", "Insurance", "Custom Deductions", "Total Deductions", "Net Pay",
          "Employer SS", "Employer Medicare", "Employer Match",
          "Employer Roth Match", "Total Payroll Cost"
        ].freeze

        def payroll_summary_by_employee_sheets(report)
          employees = Array(report[:employees])
          contractors = Array(report[:contractors])
          summary_rows = employees.map { |emp| payroll_summary_by_employee_row(emp) }
          sheets = [
            { name: "Employee Summary", rows: [ PAYROLL_SUMMARY_BY_EMPLOYEE_HEADERS ] + summary_rows },
            payroll_summary_totals_sheet(report[:summary] || {}),
            earnings_breakdown_sheet(report),
            deductions_breakdown_sheet(report)
          ]
          if contractors.any?
            sheets << { name: "Contractor Summary", rows: [ PAYROLL_SUMMARY_BY_EMPLOYEE_HEADERS ] + contractors.map { |emp| payroll_summary_by_employee_row(emp) } }
            sheets << payroll_summary_totals_sheet(
              payroll_summary_totals_for_items(contractors),
              name: "Contractor Totals",
              count_label: "Contractors"
            )
          end
          sheets << report_info_sheet(report, title: "Payroll Summary by Employee")
          sheets
        end

        def payroll_summary_by_employee_row(emp)
          total_payroll_cost = emp[:gross_pay].to_f +
            emp[:employer_social_security_tax].to_f +
            emp[:employer_medicare_tax].to_f +
            emp[:employer_retirement_match].to_f +
            emp[:employer_roth_retirement_match].to_f

          [
            emp[:employee_last_name], emp[:employee_first_name], emp[:employee_name],
            employment_type_label(emp[:employment_type]), emp[:gross_pay], emp[:reported_tips], emp[:tips_paid_out],
            emp[:bonus], emp[:custom_earnings_total], emp[:withholding_tax],
            emp[:social_security_tax], emp[:medicare_tax], emp[:retirement_payment],
            emp[:roth_retirement_payment], emp[:loan_deduction], emp[:insurance_payment],
            emp[:custom_deductions_total], emp[:total_deductions], emp[:net_pay], emp[:employer_social_security_tax],
            emp[:employer_medicare_tax], emp[:employer_retirement_match],
            emp[:employer_roth_retirement_match], total_payroll_cost
          ]
        end

        def payroll_summary_totals_sheet(summary, name: "Totals", count_label: "Employees")
          rows = [
            [ "Metric", "Amount" ],
            [ count_label, summary[:employee_count] ],
            [ "Gross Pay", summary[:total_gross] ],
            [ "Reported Tips", summary[:total_reported_tips] ],
            [ "Tips Paid Out", summary[:total_tips_paid_out] ],
            [ "Bonus", summary[:total_bonus] ],
            [ "Custom Earnings", summary[:total_custom_earnings] ],
            [ "Custom Deductions", summary[:total_custom_deductions] ],
            [ "FIT", summary[:total_withholding] ],
            [ "SS Tax", summary[:total_social_security] ],
            [ "Medicare Tax", summary[:total_medicare] ],
            [ "401(k)", summary[:total_traditional_retirement] ],
            [ "Roth 401(k)", summary[:total_roth_retirement] ],
            [ "Employer Match", summary[:total_employer_traditional_retirement] ],
            [ "Employer Roth Match", summary[:total_employer_roth_retirement] ],
            [ "Total Deductions", summary[:total_deductions] ],
            [ "Net Pay", summary[:total_net] ]
          ]
          { name: name, rows: rows }
        end

        def payroll_summary_totals_for_items(items)
          {
            employee_count: items.length,
            total_gross: items.sum { |item| item[:gross_pay].to_f },
            total_reported_tips: items.sum { |item| item[:reported_tips].to_f },
            total_tips_paid_out: items.sum { |item| item[:tips_paid_out].to_f },
            total_bonus: items.sum { |item| item[:bonus].to_f },
            total_custom_earnings: items.sum { |item| item[:custom_earnings_total].to_f },
            total_custom_deductions: items.sum { |item| item[:custom_deductions_total].to_f },
            total_withholding: items.sum { |item| item[:withholding_tax].to_f },
            total_social_security: items.sum { |item| item[:social_security_tax].to_f },
            total_medicare: items.sum { |item| item[:medicare_tax].to_f },
            total_traditional_retirement: items.sum { |item| item[:retirement_payment].to_f },
            total_roth_retirement: items.sum { |item| item[:roth_retirement_payment].to_f },
            total_employer_traditional_retirement: items.sum { |item| item[:employer_retirement_match].to_f },
            total_employer_roth_retirement: items.sum { |item| item[:employer_roth_retirement_match].to_f },
            total_deductions: items.sum { |item| item[:total_deductions].to_f },
            total_net: items.sum { |item| item[:net_pay].to_f }
          }
        end

        def payroll_export_row(emp)
          [
            emp[:employee_last_name], emp[:employee_first_name], emp[:employee_name],
            emp[:department_name], employment_type_label(emp[:employment_type]), emp[:pay_rate],
            emp[:hours_worked], emp[:overtime_hours], emp[:holiday_hours], emp[:pto_hours],
            emp[:reported_tips], emp[:tips_paid_out], emp[:bonus], emp[:custom_earnings_total],
            emp[:non_taxable_pay], emp[:gross_pay], emp[:withholding_tax], emp[:additional_withholding],
            emp[:social_security_tax], emp[:medicare_tax], emp[:employer_social_security_tax],
            emp[:employer_medicare_tax], emp[:retirement_payment], emp[:roth_retirement_payment],
            emp[:employer_retirement_match], emp[:employer_roth_retirement_match],
            emp[:loan_deduction], emp[:loan_payment], emp[:insurance_payment], emp[:custom_deductions_total], emp[:total_deductions],
            emp[:net_pay], emp[:check_number], emp[:check_date]
          ]
        end

        def earnings_breakdown_sheet(report)
          rows = [ [ "Last Name", "First Name", "Employee Name", "Category", "Label", "Hours", "Rate", "Amount" ] ]
          (Array(report[:employees]) + Array(report[:contractors])).each do |emp|
            Array(emp[:earnings_breakdown]).each do |earning|
              rows << [
                emp[:employee_last_name], emp[:employee_first_name], emp[:employee_name],
                earning[:category], earning[:label], earning[:hours], earning[:rate], earning[:amount]
              ]
            end
          end
          { name: "Earnings Detail", rows: rows }
        end

        def deductions_breakdown_sheet(report)
          rows = [ [ "Last Name", "First Name", "Employee Name", "Category", "Label", "Deduction Type", "Amount" ] ]
          (Array(report[:employees]) + Array(report[:contractors])).each do |emp|
            Array(emp[:deductions_breakdown]).each do |deduction|
              rows << [
                emp[:employee_last_name], emp[:employee_first_name], emp[:employee_name],
                deduction[:category], deduction[:label], deduction[:deduction_type], deduction[:amount]
              ]
            end
          end
          { name: "Deductions Detail", rows: rows }
        end

        def employee_pay_history_sheets(report)
          rows = [ [
            "Pay Date", "Period", "Regular Hours", "Overtime Hours", "Holiday Hours", "PTO Hours",
            "Reported Tips", "Tips Paid Out", "Bonus", "Custom Earnings", "Custom Deductions", "Gross Pay",
            "FIT", "SS Tax", "Medicare Tax", "Total Deductions", "Net Pay", "Check Number"
          ] ]
          Array(report[:history]).each do |item|
            rows << [
              item[:pay_date], item[:period_description], item[:hours_worked], item[:overtime_hours],
              item[:holiday_hours], item[:pto_hours], item[:reported_tips], item[:tips_paid_out],
              item[:bonus], item[:custom_earnings_total], item[:custom_deductions_total], item[:gross_pay], item[:withholding_tax],
              item[:social_security_tax], item[:medicare_tax], item[:total_deductions], item[:net_pay],
              item[:check_number]
            ]
          end
          [
            { name: "Pay History", rows: rows },
            { name: "YTD", rows: employee_ytd_summary_rows(report[:ytd]) },
            report_info_sheet(report, title: "Employee Pay History")
          ]
        end

        def employee_ytd_summary_rows(ytd)
          ytd ||= {}
          [
            [ "Metric", "Amount" ],
            [ "Tax Year", ytd[:year] ],
            [ "Gross Pay", ytd[:gross_pay] ],
            [ "Custom Earnings", ytd[:custom_earnings_total] ],
            [ "FIT", ytd[:withholding_tax] ],
            [ "SS Tax", ytd[:social_security_tax] ],
            [ "Medicare Tax", ytd[:medicare_tax] ],
            [ "401(k)", ytd[:retirement] ],
            [ "Roth 401(k)", ytd[:roth_retirement] ],
            [ "Tips", ytd[:tips] ],
            [ "Tips Paid Out", ytd[:tips_paid_out] ],
            [ "Bonus", ytd[:bonus] ],
            [ "Total Deductions", ytd[:total_deductions] ],
            [ "Custom Deductions", ytd[:custom_deductions_total] ],
            [ "Net Pay", ytd[:net_pay] ]
          ]
        end

        def tax_summary_sheets(report)
          totals = report[:totals] || {}
          rows = [ [ "Category", "Amount" ] ] + totals.map { |key, value| [ key.to_s.humanize, value ] }
          meta = [ [ "Field", "Value" ], [ "Year", report.dig(:period, :year) ], [ "Quarter", report.dig(:period, :quarter) ], [ "Pay Periods", report[:pay_periods_included] ], [ "Employees", report[:employee_count] ] ]
          [
            { name: "Summary", rows: rows },
            { name: "Meta", rows: meta },
            report_info_sheet(report, title: "Tax Summary")
          ]
        end

        def ytd_summary_sheets(report)
          rows = [ [
            "Last Name", "First Name", "Employee Name", "Type", "Status", "Gross Pay",
            "Custom Earnings", "Tips", "Tips Paid Out", "Bonus", "FIT", "SS Tax", "Medicare Tax",
            "401(k)", "Roth 401(k)", "Total Deductions", "Custom Deductions", "Net Pay"
          ] ]
          Array(report[:employees]).each do |emp|
            rows << [
              emp[:last_name], emp[:first_name], emp[:name], employment_type_label(emp[:employment_type]), emp[:status],
              emp[:gross_pay], emp[:custom_earnings_total], emp[:tips], emp[:tips_paid_out], emp[:bonus],
              emp[:withholding_tax], emp[:social_security_tax], emp[:medicare_tax],
              emp[:retirement], emp[:roth_retirement], emp[:total_deductions], emp[:custom_deductions_total], emp[:net_pay]
            ]
          end
          [
            { name: "YTD Summary", rows: rows },
            { name: "Company Totals", rows: (report[:company_totals] || {}).to_a },
            report_info_sheet(report, title: "YTD Summary")
          ]
        end

        def form_941_gu_sheets(report)
          lines = report[:lines] || {}
          tax_detail = report[:tax_detail] || {}
          monthly = Array(report[:monthly_liability])
          [
            {
              name: "Federal 941 Lines",
              rows: [ [ "Line", "Amount" ] ] + lines.map { |key, value| [ key.to_s.humanize, value ] }
            },
            {
              name: "Tax Detail",
              rows: [ [ "Category", "Amount" ] ] + tax_detail.map { |key, value| [ key.to_s.humanize, value ] }
            },
            {
              name: "Monthly Liability",
              rows: [ [ "Month", "Guam Withholding For W-1", "SS Wages Combined", "SS Tips Combined", "Medicare Combined", "Additional Medicare", "Federal Liability Total" ] ] +
                monthly.map { |row| [ row[:month], row[:guam_withholding_for_w1], row[:ss_combined], row[:ss_tips_combined], row[:medicare_combined], row[:add_medicare_tax], row[:total_liability] ] }
            },
            report_info_sheet(report, title: "Federal Form 941", description: REPORT_DESCRIPTIONS[:form_941_gu])
          ]
        end

        def quarterly_compliance_packet_sheets(report)
          form500_deposits = Array(report.dig(:form_500, :deposits))
          w1_daily = Array(report.dig(:w1, :daily_liabilities))
          w1_monthly = Array(report.dig(:w1, :monthly_liabilities))
          swica_employees = Array(report.dig(:swica, :employees))
          component_rows = Array(report[:component_taxability])
          federal_lines = report.dig(:federal_941, :report, :lines) || {}
          checks = Array(report[:review_checks])

          [
            {
              name: "Packet Summary",
              rows: [
                [ "Field", "Value" ],
                [ "Company", report.dig(:meta, :company_name) ],
                [ "EIN", report.dig(:meta, :ein) ],
                [ "Quarter", report.dig(:meta, :quarter_label) ],
                [ "Period Basis", report.dig(:meta, :period_basis) ],
                [ "Official Due Date", report.dig(:due_dates, :official_due_date) ],
                [ "Internal Target Date", report.dig(:due_dates, :internal_target_date) ],
                [ "Pay Periods Included", report.dig(:meta, :pay_periods_included) ]
              ]
            },
            {
              name: "Form 500 Deposits",
              rows: [ [ "Pay Period ID", "Pay Date", "Quarter Ending", "Amount", "Status", "Payment Date", "Confirmation", "Receipt Attached" ] ] +
                form500_deposits.map { |row| [ row[:pay_period_id], row[:pay_date], row[:quarter_ending], row[:amount], row[:status], row[:payment_date], row[:confirmation_number], row[:receipt_attached] ] }
            },
            {
              name: "W-1 Daily",
              rows: [ [ "Pay Date", "Month", "Guam Withholding Liability" ] ] +
                w1_daily.map { |row| [ row[:pay_date], row[:month], row[:amount] ] }
            },
            {
              name: "W-1 Monthly",
              rows: [ [ "Month", "Month Number", "Guam Withholding Liability" ] ] +
                w1_monthly.map { |row| [ row[:month], row[:month_number], row[:amount] ] }
            },
            {
              name: "SWICA Detail",
              rows: [ [ "Employee", "SSN Last 4", "Status", "Termination Date", "SWICA Wages", "Reported Tips", "Non-Taxable Pay", "Guam Withholding", "Pay Dates" ] ] +
                swica_employees.map { |row| [ row[:name], row[:ssn_last_four], row[:status], row[:termination_date], row[:swica_wages], row[:reported_tips], row[:non_taxable_pay], row[:guam_withholding], Array(row[:pay_dates]).join(", ") ] }
            },
            {
              name: "Federal 941",
              rows: [ [ "Line", "Amount" ] ] + federal_lines.map { |key, value| [ key.to_s.humanize, value ] }
            },
            {
              name: "Taxability Map",
              rows: [ [ "Category", "Label", "Amount", "Guam Wages", "SWICA Wages", "SS Wages", "SS Tips", "Medicare Wages", "Non-Taxable" ] ] +
                component_rows.map { |row| [ row[:category], row[:label], row[:amount], row[:guam_withholding_wages], row[:swica_wages], row[:social_security_wages], row[:social_security_tips], row[:medicare_wages_tips], row[:non_taxable] ] }
            },
            {
              name: "Review Checks",
              rows: [ [ "Check", "Status", "Message" ] ] +
                checks.map { |row| [ row[:key], row[:status], row[:message] ] }
            },
            report_info_sheet(report, title: "Quarterly Compliance Packet", description: REPORT_DESCRIPTIONS[:quarterly_compliance_packet])
          ]
        end

        def w2_gu_sheets(report)
          headers = [
            "Employee Name", "SSN Last 4", "Box 1 Wages Tips Other Comp", "Box 2 FIT",
            "Box 3 SS Wages", "Box 4 SS Tax", "Box 5 Medicare Wages Tips",
            "Box 6 Medicare Tax", "Box 7 SS Tips", "Reported Tips", "Non-Taxable Pay"
          ]
          rows = Array(report[:employees]).map do |emp|
            [
              emp[:employee_name], emp[:employee_ssn_last4], emp[:box1_wages_tips_other_comp],
              emp[:box2_federal_income_tax_withheld], emp[:box3_social_security_wages],
              emp[:box4_social_security_tax_withheld], emp[:box5_medicare_wages_tips],
              emp[:box6_medicare_tax_withheld], emp[:box7_social_security_tips],
              emp[:reported_tips_total], emp[:non_taxable_total]
            ]
          end
          [
            { name: "W-2GU", rows: [ headers ] + rows },
            { name: "Totals", rows: (report[:totals] || {}).to_a },
            report_info_sheet(report, title: "W-2GU", description: REPORT_DESCRIPTIONS[:w2_gu])
          ]
        end

        def form_1099_nec_sheets(report)
          headers = [
            "Contractor", "Business Name", "Type", "TIN Type", "TIN Last 4",
            "Total Compensation", "Federal Withheld", "Payment Count", "Requires Filing", "W-9 On File", "Compliance Issues"
          ]
          rows = Array(report[:all_contractors]).map do |contractor|
            [
              contractor[:name], contractor[:business_name], contractor[:contractor_type],
              contractor[:tin_type], contractor[:tin_last_four], contractor[:total_compensation],
              contractor[:federal_withheld], contractor[:payment_count], contractor[:requires_filing],
              contractor[:w9_on_file], Array(contractor[:compliance_issues]).join("; ")
            ]
          end
          [
            { name: "1099-NEC", rows: [ headers ] + rows },
            { name: "Totals", rows: (report[:totals] || {}).to_a },
            report_info_sheet(report, title: "1099-NEC", description: REPORT_DESCRIPTIONS[:form_1099_nec])
          ]
        end

        def deductions_contributions_sheets(pay_period)
          report = build_pay_period_payroll_items_report(pay_period)
          [
            deductions_breakdown_sheet(report),
            { name: "Payroll Rows", rows: [ PAYROLL_REGISTER_HEADERS ] + (Array(report[:employees]) + Array(report[:contractors])).map { |emp| payroll_export_row(emp) } },
            report_info_sheet(report, title: "Deductions & Contributions", description: REPORT_DESCRIPTIONS[:deductions_contributions])
          ]
        end

        def paycheck_history_sheets(pay_period)
          report = build_pay_period_payroll_items_report(pay_period)
          [
            { name: "Paycheck History", rows: [ PAYROLL_REGISTER_HEADERS ] + (Array(report[:employees]) + Array(report[:contractors])).map { |emp| payroll_export_row(emp) } },
            report_info_sheet(report, title: "Paycheck History", description: REPORT_DESCRIPTIONS[:paycheck_history])
          ]
        end

        def retirement_plans_sheets(pay_period)
          report = build_pay_period_payroll_items_report(pay_period)
          headers = [ "Last Name", "First Name", "Employee Name", "Gross Pay", "401(k)", "Roth 401(k)", "Employer Match", "Employer Roth Match", "Total Employee", "Total Employer" ]
          rows = Array(report[:employees]).map do |emp|
            [
              emp[:employee_last_name], emp[:employee_first_name], emp[:employee_name], emp[:gross_pay],
              emp[:retirement_payment], emp[:roth_retirement_payment], emp[:employer_retirement_match],
              emp[:employer_roth_retirement_match], emp[:total_retirement_payment], emp[:total_employer_retirement_match]
            ]
          end
          [
            { name: "Retirement", rows: [ headers ] + rows },
            report_info_sheet(report, title: "Retirement Plans Report", description: REPORT_DESCRIPTIONS[:retirement_plans])
          ]
        end

        def installment_loans_sheets(company, as_of_date: nil)
          as_of = as_of_date || Date.current
          rows = [ [ "Last Name", "First Name", "Employee Name", "Loan", "Status", "Original Amount", "Balance As Of", "As Of Date", "Date", "Type", "Amount", "Beginning Balance", "Ending Balance" ] ]
          InstallmentLoanReportBuilder.new(company, as_of_date: as_of).loans.each do |snapshot|
            loan = snapshot[:loan]
            employee = snapshot[:employee]
            if snapshot[:transactions].empty?
              rows << [ employee.last_name, employee.first_name, employee.full_name, loan.name, snapshot[:status_as_of], loan.original_amount, snapshot[:balance_as_of], as_of, nil, nil, nil, nil, nil ]
            else
              snapshot[:transactions].each do |txn|
                rows << [
                  employee.last_name, employee.first_name, employee.full_name, loan.name,
                  snapshot[:status_as_of], loan.original_amount, snapshot[:balance_as_of], as_of, txn.transaction_date,
                  txn.transaction_type, txn.amount, txn.balance_before, txn.balance_after
                ]
              end
            end
          end
          [
            { name: "Installment Loans", rows: rows },
            report_info_sheet(
              { meta: report_meta(company, :installment_loans) },
              title: "Employee Installment Loans",
              description: REPORT_DESCRIPTIONS[:installment_loans]
            )
          ]
        end

        def apply_preflight_to_filing!(filing, preflight, update_preflight_run_at:)
          was_filing_ready = !filing.new_record? && filing.status == "filing_ready"

          filing.blocking_count = preflight[:blocking_count]
          if update_preflight_run_at
            filing.warning_count = preflight[:warning_count]
            filing.findings = preflight[:findings]
            filing.preflight_run_at = Time.current
          end

          if preflight[:blocking_count].zero?
            filing.status = was_filing_ready ? "filing_ready" : "preflight_passed"
          else
            filing.status = "draft"
            filing.marked_ready_at = nil
            filing.marked_ready_by_id = nil
            filing.notes = nil
          end
        end

        def filing_readiness_payload(filing)
          {
            year: filing.year,
            status: filing.status,
            blocking_count: filing.blocking_count,
            warning_count: filing.warning_count,
            preflight_run_at: filing.preflight_run_at,
            marked_ready_at: filing.marked_ready_at,
            marked_ready_by_id: filing.marked_ready_by_id,
            notes: filing.notes,
            findings: filing.findings,
            findings_source: "persisted"
          }
        end

        def revalidation_payload(preflight)
          {
            year: preflight[:year],
            company_id: preflight[:company_id],
            company_name: preflight[:company_name],
            run_at: preflight[:run_at],
            blocking_count: preflight[:blocking_count],
            warning_count: preflight[:warning_count],
            findings: preflight[:findings],
            findings_source: "revalidation"
          }
        end

        def parse_optional_iso_date(value, param_name:)
          return if value.blank?

          Date.iso8601(value)
        rescue ArgumentError, Date::Error
          render json: { error: "Invalid #{param_name} - expected YYYY-MM-DD" }, status: :unprocessable_entity
          nil
        end

        def parse_tax_year_param
          year = params[:year].present? ? Integer(params[:year], exception: false) : Date.current.year
          return year if year && year > 2000 && year <= Date.current.year + 1

          render json: { error: "year must be a valid 4-digit tax year" }, status: :unprocessable_entity
          nil
        end
      end
    end
  end
end
