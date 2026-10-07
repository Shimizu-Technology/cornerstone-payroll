# frozen_string_literal: true

# Capped amounts are calculation results, not replacement employee requests.
# Loan request evidence predates any scheduled/available-pay cap; uncapped_amount
# can contain an intermediate scheduled amount when both limits were applied.
class PayrollFieldRequestIntent
  METADATA_KEYS = %w[loan_requested_amount uncapped_amount].freeze

  def self.replace_request?(data)
    return false unless data.key?("replace_request") || data.key?(:replace_request)

    flag = data.key?("replace_request") ? data["replace_request"] : data[:replace_request]
    unless [ true, false ].include?(flag)
      raise ArgumentError, "Payroll field replace_request must be a JSON boolean (true or false)"
    end
    flag
  end

  def self.requested_amount(entry)
    return nil unless entry

    metadata_amounts(entry).first || entry.amount.to_d.round(2)
  end

  def self.unchanged_echo?(entry, amount)
    [ entry.amount.to_d.round(2), *metadata_amounts(entry) ].include?(amount)
  end

  def self.metadata_amounts(entry)
    metadata = entry.metadata.to_h
    METADATA_KEYS.filter_map do |key|
      next if metadata[key].nil?

      amount = BigDecimal(metadata[key].to_s)
      amount.round(2) if amount.finite? && amount >= 0
    rescue ArgumentError, TypeError
      nil
    end
  end
end
