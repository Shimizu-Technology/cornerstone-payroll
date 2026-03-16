# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ReportsController < BaseController
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

        # GET /api/v1/admin/reports/employee_pay_history
        # Individual employee pay records
        def employee_pay_history
          employee = Employee.find(params[:employee_id])

          unless employee.company_id == current_company_id
            return render json: { error: "Employee not found" }, status: :not_found
          end

          items = employee.payroll_items
                         .includes(:pay_period)
                         .where(pay_periods: {
                           id: PayPeriod.reportable_committed
                                        .where(company_id: employee.company_id)
                                        .select(:id)
                         })
                         .order("pay_periods.pay_date DESC")
                         .limit(params[:limit] || 12)

          render json: {
            report: {
              type: "employee_pay_history",
              employee: {
                id: employee.id,
                name: employee.full_name,
                employment_type: employee.employment_type,
                pay_rate: employee.pay_rate
              },
              history: items.map { |item| pay_history_item(item) },
              ytd: employee_ytd_summary(employee)
            }
          }
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

        # GET /api/v1/admin/reports/form_941_gu
        # Quarterly 941-GU style payroll tax report for Guam DoRT filing.
        #
        # Params:
        #   year    [Integer] – tax year (defaults to current year)
        #   quarter [Integer] – 1, 2, 3, or 4 (required)
        #
        # Response: structured JSON mirroring 941-GU line items.
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

        # GET /api/v1/admin/reports/ytd_summary
        # Year-to-date summary for all employees
        def ytd_summary
          year = params[:year]&.to_i || Date.current.year

          employees = Employee.where(company_id: current_company_id)
                             .includes(:employee_ytd_totals)
                             .order(:last_name, :first_name)

          render json: {
            report: {
              type: "ytd_summary",
              year: year,
              employees: employees.map { |emp| employee_ytd_row(emp, year) },
              company_totals: ytd_company_totals(year)
            }
          }
        end

        private

        # Shared data builder for payroll register (JSON + CSV + PDF).
        # Returns [report_data, nil] on success or [nil, rendered_response] on error.
        # pay_period_id param is required.
        def build_payroll_register_data
          pay_period_id = params[:pay_period_id]

          if pay_period_id.blank?
            return [ nil, render(json: { error: "pay_period_id is required" }, status: :unprocessable_entity) ]
          end

          pay_period = PayPeriod.includes(payroll_items: :employee).find_by(id: pay_period_id)

          unless pay_period && pay_period.company_id == current_company_id
            return [ nil, render(json: { error: "Pay period not found" }, status: :not_found) ]
          end

          items = pay_period.payroll_items

          report_data = {
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
              employee_count: items.size,
              total_gross: items.sum(&:gross_pay),
              total_withholding: items.sum(&:withholding_tax),
              total_social_security: items.sum(&:social_security_tax),
              total_medicare: items.sum(&:medicare_tax),
              total_retirement: items.sum(&:retirement_payment),
              total_deductions: items.sum(&:total_deductions),
              total_net: items.sum(&:net_pay)
            },
            employees: items.map { |item| payroll_item_detail(item) }
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

          items                   = PayrollItem.joins(:pay_period).where(pay_periods: { id: pay_periods.pluck(:id) })
          employee_ss_total       = items.sum(:social_security_tax)
          employee_medicare_total = items.sum(:medicare_tax)
          employer_ss_total       = items.sum(:employer_social_security_tax)
          employer_medicare_total = items.sum(:employer_medicare_tax)
          withholding_total       = items.sum(:withholding_tax)

          report_data = {
            type: "tax_summary",
            meta: { generated_at: Time.current.iso8601 },
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
            employee_count: pp.payroll_items.count,
            total_gross: pp.payroll_items.sum(:gross_pay),
            total_net: pp.payroll_items.sum(:net_pay)
          }
        end

        def ytd_company_totals(year = Date.current.year)
          reportable_period_ids = PayPeriod.reportable_committed
                                           .where(company_id: current_company_id)
                                           .where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
                                           .select(:id)

          items = PayrollItem.joins(:pay_period)
                            .where(pay_periods: {
                              id: reportable_period_ids
                            })

          {
            year: year,
            gross_pay: items.sum(:gross_pay),
            withholding_tax: items.sum(:withholding_tax),
            social_security_tax: items.sum(:social_security_tax),
            medicare_tax: items.sum(:medicare_tax),
            retirement: items.sum(:retirement_payment),
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
              employee_count: pp.payroll_items.count,
              total_net: pp.payroll_items.sum(:net_pay)
            }
          end
        end

        def payroll_item_detail(item)
          {
            employee_id: item.employee_id,
            employee_name: item.employee.full_name,
            employment_type: item.employment_type,
            pay_rate: item.pay_rate,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            retirement_payment: item.retirement_payment,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            check_number: item.check_number
          }
        end

        def pay_history_item(item)
          {
            pay_period_id: item.pay_period_id,
            pay_date: item.pay_period.pay_date,
            period_description: item.pay_period.period_description,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            gross_pay: item.gross_pay,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            check_number: item.check_number
          }
        end

        def employee_ytd_summary(employee, year = Date.current.year)
          ytd = employee.ytd_totals_for(year)
          {
            year: year,
            gross_pay: ytd.gross_pay,
            withholding_tax: ytd.withholding_tax,
            social_security_tax: ytd.social_security_tax,
            medicare_tax: ytd.medicare_tax,
            retirement: ytd.retirement,
            net_pay: ytd.net_pay
          }
        end

        def employee_ytd_row(employee, year)
          ytd = employee.employee_ytd_totals.find_by(year: year)

          {
            employee_id: employee.id,
            name: employee.full_name,
            employment_type: employee.employment_type,
            status: employee.status,
            gross_pay: ytd&.gross_pay || 0,
            withholding_tax: ytd&.withholding_tax || 0,
            social_security_tax: ytd&.social_security_tax || 0,
            medicare_tax: ytd&.medicare_tax || 0,
            retirement: ytd&.retirement || 0,
            net_pay: ytd&.net_pay || 0
          }
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
      end
    end
  end
end
