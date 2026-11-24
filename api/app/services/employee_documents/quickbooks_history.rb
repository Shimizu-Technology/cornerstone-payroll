# frozen_string_literal: true

module EmployeeDocuments
  class QuickbooksHistory
    AMOUNTS = (HistoricalPaycheckAdjustment::MONEY_FIELDS + [ :hours_total ]).freeze

    def self.scope(company_id)
      cutover = PayPeriod.committed.where(company_id: company_id, source_pay_period_id: nil)
        .where("promotion_payment_disposition IS DISTINCT FROM 'record_only'").minimum(:pay_date)
      return HistoricalPaycheck.none unless cutover

      HistoricalPaycheck.joins(:historical_import_batch, :historical_pay_period, :employee)
        .where(company_id: company_id, pay_date: cutover.beginning_of_year...cutover, reconciliation_status: "matched")
        .where(employees: { company_id: company_id })
        .where(historical_import_batches: { company_id: company_id, status: "locked", source_system: "quickbooks_online" })
        .where(historical_pay_periods: { company_id: company_id, period_type: "regular" })
    end

    def self.review_warnings(company_id)
      checks = scope(company_id)
      counts = checks.group(:employee_id).having("COUNT(*) > COUNT(DISTINCT historical_paychecks.pay_date)").count
      duplicate_groups = checks.group(:employee_id, :pay_date, :net_pay, :gross_pay).having("COUNT(*) > 1").count
        .keys.map(&:first).tally
      Employee.where(company_id: company_id, id: counts.keys | duplicate_groups.keys).map do |employee|
        {
          employee_id: employee.id, employee_name: employee.full_name,
          row_count: counts.fetch(employee.id, 0), duplicate_groups: duplicate_groups.fetch(employee.id, 0)
        }
      end.sort_by { |warning| warning[:employee_name] }
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
