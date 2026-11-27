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

  # A statement deduction row's printed label, the same on the earnings
  # statement, the employee app and the check stub.
  def self.deduction(row)
    case row.semantic
    when PayrollReportingGroups::GROUP_401K_PRE_TAX.to_sym
      "401(k) Retirement"
    when :loan
      row.label == "Loan" ? "Loan Repayment" : row.label
    else
      row.label
    end
  end
end
