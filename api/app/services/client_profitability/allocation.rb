# frozen_string_literal: true

module ClientProfitability
  # Splits an amount of money across keys in proportion to weights, to the
  # cent, so the parts always add back to the amount (largest remainder).
  module Allocation
    module_function

    def split(amount, weights)
      weights = weights.select { |_key, weight| weight.to_d.positive? }
      return {} if weights.empty?

      total_weight = weights.values.sum(BigDecimal("0"), &:to_d)
      cents = (amount.to_d * 100).round(0, :half_up).to_i
      raw = weights.transform_values { |weight| BigDecimal(cents) * weight.to_d / total_weight }
      parts = raw.transform_values { |value| value.floor.to_i }
      remainder = cents - parts.values.sum
      raw.sort_by { |key, value| [ -(value - value.floor), key.to_s ] }.first(remainder).each { |key, _value| parts[key] += 1 }
      parts.transform_values { |part| BigDecimal(part) / 100 }
    end
  end
end
