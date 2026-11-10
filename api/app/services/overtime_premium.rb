# frozen_string_literal: true

# Overtime premium is an employee protection. A 1099 contractor is paid the
# contract rate for every hour, including hours a time source reports as overtime.
module OvertimePremium
  EMPLOYEE_MULTIPLIER = BigDecimal("1.5")

  def self.multiplier(employment_type)
    employment_type.to_s == "contractor" ? BigDecimal("1") : EMPLOYEE_MULTIPLIER
  end

  # Contractor earnings hold one contract-rate row per rate, combining the
  # source's REG and OT hours. The item keeps the split; history reviews that
  # compare REG/OT by earning row read the split from the item's rate buckets.
  def self.combined_contract_rows?(item, earnings)
    item.employment_type.to_s == "contractor" && Array(item.wage_rate_hours).any? &&
      item.overtime_hours.to_d.nonzero? && earnings.none? { |earning| earning.category == "overtime" } &&
      earnings.sum(0.to_d) { |earning| earning.hours.to_d } == item.hours_worked.to_d + item.overtime_hours.to_d
  end
end
