# frozen_string_literal: true

# Identity-only population; full preflight retains responsibility for validating
# historical bridge freshness before marking a filing ready.
class W2GuFilingPopulation
  def self.employees(company:, year:)
    ids = native_employee_ids(company: company, year: year) +
      HistoricalPayrollFilingSource.new(company).annual_employee_ids(year)
    Employee.where(company_id: company.id, id: ids.uniq).order(:last_name, :first_name, :id)
  end

  def self.native_employee_ids(company:, year:)
    year_range = Date.new(year, 1, 1)..Date.new(year, 12, 31)
    PayrollItem
      .joins(:pay_period)
      .where(company_id: company.id)
      .financially_reportable.reportable
      .where.not(employment_type: "contractor")
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
          .where(company_id: company.id, pay_date: year_range)
          .select(:id)
      })
      .distinct
      .pluck(:employee_id)
  end
end
