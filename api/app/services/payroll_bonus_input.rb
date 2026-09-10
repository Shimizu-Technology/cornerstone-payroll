# frozen_string_literal: true

# Bonus input belongs to one paycheck. Retain the latest explicit source amount
# separately so a reimport cannot silently replace an operator's correction.
class PayrollBonusInput
  def self.manual!(item, value)
    item.bonus = amount(value)
    item.bonus_source = "manual"
  end

  def self.import!(item, value)
    return if value.nil?

    source_amount = amount(value)
    item.imported_bonus = source_amount
    return if manual?(item)

    item.bonus = source_amount
    item.bonus_source = "mosa_revel"
  end

  def self.manual?(item)
    item.bonus_source == "manual" || (item.bonus_source.nil? && item.bonus.to_d.positive?)
  end

  def self.amount(value)
    parsed = BigDecimal(value.to_s, exception: false)
    unless parsed&.finite? && parsed >= 0 && parsed <= BigDecimal("99999999.99")
      raise ArgumentError, "Bonus must be a valid amount of zero or more."
    end

    parsed.round(2)
  end
end
