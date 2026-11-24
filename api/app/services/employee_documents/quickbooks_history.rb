# frozen_string_literal: true

module EmployeeDocuments
  class QuickbooksHistory
    PAY_DATES = Date.new(2026, 1, 1)..Date.new(2026, 8, 31)
    AMOUNTS = (HistoricalPaycheckAdjustment::MONEY_FIELDS + [ :hours_total ]).freeze

    def self.scope(company_id)
      HistoricalPaycheck.joins(:historical_import_batch, :historical_pay_period, :employee)
        .where(company_id: company_id, pay_date: PAY_DATES, reconciliation_status: "matched")
        .where(employees: { company_id: company_id })
        .where(historical_import_batches: { company_id: company_id, status: "locked", source_system: "quickbooks_online" })
        .where(historical_pay_periods: { company_id: company_id, period_type: "regular" })
    end

    def self.for(employee)
      scope(employee.company_id).where(employee_id: employee.id)
        .includes(:historical_paycheck_adjustments).order(pay_date: :desc, id: :desc).map do |check|
          adjustments = check.historical_paycheck_adjustments
          totals = AMOUNTS.index_with do |field|
            check.public_send(field).to_d + adjustments.sum { |row| row.public_send(field).to_d }
          end
          totals.merge(
            historical_paycheck_id: check.id, pay_date: check.pay_date,
            period_start: check.period_start, period_end: check.period_end,
            check_number: check.check_number, payment_method: check.payment_method,
            source_label: "From QuickBooks records",
            adjustment_note: ("Includes recorded payroll adjustments." if adjustments.any?)
          )
        end
    end
  end
end
