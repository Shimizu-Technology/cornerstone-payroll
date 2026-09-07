# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ImportedPayPeriodsController < BaseController
        DEFAULT_PER_PAGE = 50
        MAX_PER_PAGE = 100

        def show
          period = HistoricalPayPeriod
            .joins(:historical_import_batch)
            .includes(historical_import_batch: :locked_by)
            .where(company_id: current_company_id, period_type: "regular")
            .where(historical_import_batches: { company_id: current_company_id, status: "locked" })
            .find(params[:id])

          page = [ params.fetch(:page, 1).to_i, 1 ].max
          per_page = params.fetch(:per_page, DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
          scope = period.historical_paychecks.includes(:employee, :historical_worker)
                        .order(Arel.sql("source_employee_name ASC, id ASC"))
          total_count = scope.count
          paychecks = scope.offset((page - 1) * per_page).limit(per_page)
          batch = period.historical_import_batch

          render json: {
            data: {
              key: "imported:#{period.id}",
              record_type: "imported",
              id: period.id,
              company_id: period.company_id,
              start_date: period.start_date,
              end_date: period.end_date,
              pay_date: period.pay_date,
              status: "locked",
              run_purpose: "regular",
              includes_base_salary: true,
              correction_status: nil,
              notes: nil,
              compliance_warnings: [],
              employee_count: period.paycheck_count,
              total_gross: money(period.totals["gross_pay"]),
              total_net: money(period.totals["net_pay"]),
              source: {
                system: batch.source_system,
                label: "QuickBooks import",
                detail: period.source_label,
                locked: true,
                import_batch_id: batch.id,
                importer_version: batch.importer_version,
                locked_at: batch.locked_at,
                locked_by_name: batch.locked_by&.name
              },
              capabilities: {
                view: true,
                edit: false,
                delete: false,
                enter_hours: false,
                run: false,
                approve: false,
                commit: false
              },
              paychecks: paychecks.map { |paycheck| paycheck_json(paycheck) }
            },
            meta: {
              current_page: page,
              per_page: per_page,
              total_count: total_count,
              total_pages: (total_count.to_f / per_page).ceil
            }
          }
        end

        private

        def money(value)
          (BigDecimal(value.to_s, exception: false) || 0).to_f
        end

        def paycheck_json(paycheck)
          {
            id: paycheck.id,
            employee_id: paycheck.employee_id,
            employee_name: paycheck.employee&.full_name,
            source_employee_name: paycheck.source_employee_name,
            check_number: paycheck.check_number,
            payment_method: paycheck.payment_method,
            source_status: paycheck.source_status,
            reconciliation_status: paycheck.reconciliation_status,
            hours_total: paycheck.hours_total.to_s,
            gross_pay: paycheck.gross_pay.to_s,
            adjusted_gross: paycheck.adjusted_gross.to_s,
            pretax_deductions: paycheck.pretax_deductions.to_s,
            employee_taxes: paycheck.employee_taxes.to_s,
            federal_income_tax: paycheck.federal_income_tax.to_s,
            social_security_tax: paycheck.social_security_tax.to_s,
            medicare_tax: paycheck.medicare_tax.to_s,
            after_tax_deductions: paycheck.after_tax_deductions.to_s,
            net_pay: paycheck.net_pay.to_s,
            employer_taxes: paycheck.employer_taxes.to_s,
            employer_contributions: paycheck.employer_contributions.to_s,
            total_payroll_cost: paycheck.total_payroll_cost.to_s,
            hours_breakdown: paycheck.hours_breakdown,
            earnings_breakdown: paycheck.earnings_breakdown,
            pretax_deduction_breakdown: paycheck.pretax_deduction_breakdown,
            after_tax_deduction_breakdown: paycheck.after_tax_deduction_breakdown,
            employee_tax_breakdown: paycheck.employee_tax_breakdown,
            employer_tax_breakdown: paycheck.employer_tax_breakdown,
            employer_contribution_breakdown: paycheck.employer_contribution_breakdown
          }
        end
      end
    end
  end
end
