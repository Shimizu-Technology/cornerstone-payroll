# frozen_string_literal: true

# The stored employee Medicare amount INCLUDES Additional Medicare. Employer
# Medicare is separate and must never be used to infer employee withholding.
class PayrollTaxSummary
  def initialize(item)
    @item = item
  end

  def total
    (@item.withholding_tax.to_d + @item.additional_withholding.to_d +
      @item.social_security_tax.to_d + @item.medicare_tax.to_d).round(2)
  end

  def lines
    [
      { label: "Federal income tax", amount: @item.withholding_tax.to_d },
      { label: "Additional W-4 withholding", amount: @item.additional_withholding.to_d },
      { label: "Social Security", amount: @item.social_security_tax.to_d },
      { label: "Medicare (base)", amount: @item.medicare_tax.to_d - @item.additional_medicare_tax.to_d },
      { label: "Additional Medicare", amount: @item.additional_medicare_tax.to_d }
    ].map { |line| line.merge(amount: line[:amount].round(2).to_f) }
  end
end
