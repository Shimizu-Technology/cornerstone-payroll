# frozen_string_literal: true

module YearEnd
  # The committed payroll rows a year's W-2GUs sum: financially reportable,
  # non-contractor items in reportable committed pay periods paid that year.
  # It is the same population as W2GuAggregator's live items.
  module W2PayrollItems
    def self.scope(company_ids, year)
      range = Date.new(year, 1, 1)..Date.new(year, 12, 31)
      PayrollItem
        .joins(:pay_period)
        .where(company_id: company_ids)
        .financially_reportable.reportable
        .where.not(employment_type: "contractor")
        .where(pay_periods: { id: PayPeriod.reportable_committed.where(company_id: company_ids, pay_date: range).select(:id) })
    end
  end
end
