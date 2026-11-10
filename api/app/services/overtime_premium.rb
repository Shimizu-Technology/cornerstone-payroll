# frozen_string_literal: true

# Overtime premium is an employee protection. A 1099 contractor is paid the
# contract rate for every hour, including hours a time source reports as overtime.
module OvertimePremium
  EMPLOYEE_MULTIPLIER = BigDecimal("1.5")

  def self.multiplier(employment_type)
    employment_type.to_s == "contractor" ? BigDecimal("1") : EMPLOYEE_MULTIPLIER
  end
end
