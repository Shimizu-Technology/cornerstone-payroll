# frozen_string_literal: true

# Hours on an imported paycheck, by kind. The imported payroll register and
# the combined reports read them here, so both views always agree.
module ImportedPaycheckHours
  HOLIDAY = /holiday/i
  PTO = /pto|paid time/i

  module_function

  # The hours on lines whose squished label matches, or nil when none does.
  def component(paycheck, pattern)
    amounts = Array(paycheck.hours_breakdown).filter_map do |entry|
      line = entry.to_h.with_indifferent_access
      BigDecimal(line[:amount].to_s, exception: false) if line[:label].to_s.squish.match?(pattern)
    end
    amounts.sum(0.to_d) if amounts.any?
  end

  # The source's regular line. A source that records none keeps the imported
  # total less its overtime, holiday and PTO hours, never below zero.
  def regular(paycheck)
    recorded = component(paycheck, UnifiedPayrollReporting::REGULAR_HOURS)
    return recorded if recorded

    other = [ UnifiedPayrollReporting::OVERTIME_HOURS, HOLIDAY, PTO ].sum(0.to_d) { |pattern| component(paycheck, pattern).to_d }
    [ paycheck.hours_total.to_d - other, 0.to_d ].max
  end
end
