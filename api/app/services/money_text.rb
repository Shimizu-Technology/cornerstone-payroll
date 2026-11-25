# frozen_string_literal: true

# Money as printed on statements, checks and filing copies: decimal cents
# rounded half up (never through Float), thousands delimited, and the sign
# before the dollar sign ("-$12.34").
module MoneyText
  def self.amount(value)
    ActiveSupport::NumberHelper.number_to_rounded(cents(value), precision: 2, delimiter: ",")
  end

  def self.currency(value)
    ActiveSupport::NumberHelper.number_to_currency(cents(value), precision: 2)
  end

  def self.cents(value)
    value.nil? ? 0.to_d : value.to_d.round(2)
  end
  private_class_method :cents
end
