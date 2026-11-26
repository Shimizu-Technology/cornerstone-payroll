# frozen_string_literal: true

module PayrollLabels
  # Form W-2GU, box 2.
  INCOME_TAX = "Guam income tax"
  INCOME_TAX_WITHHELD = "#{INCOME_TAX} withheld"
  ADDITIONAL_WITHHOLDING = "Additional #{INCOME_TAX} (W-4 4c)"
  COMPACT_ADDITIONAL_WITHHOLDING = "Add'l #{INCOME_TAX} (4c)"

  STUB_TAXES = {
    income_tax: INCOME_TAX,
    social_security: "Social Security (6.2%)",
    medicare: "Medicare",
    additional_medicare: "Additional Medicare",
    additional_withholding: ADDITIONAL_WITHHOLDING
  }.freeze
end
