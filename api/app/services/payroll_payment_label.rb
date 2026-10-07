# frozen_string_literal: true

# Presentation only: use the payroll snapshot, never today's employee default
# to reinterpret a committed paycheck or a retained historical source.
class PayrollPaymentLabel
  ZERO_NET = "$0 net · earnings statement only"
  ADJUSTMENT = "Adjustment — no payment issued"

  def self.for(item)
    return ADJUSTMENT if item.net_pay.to_d.negative?
    return ZERO_NET if item.net_pay.to_d.zero?
    return "Direct deposit" if item.effective_payment_delivery_method == "direct_deposit"

    item.check_number.present? ? "Paper check" : "Paper check · not assigned"
  end

  def self.history_row(row)
    return row[:payment_method_label] if row[:payment_method_label].present?
    return ADJUSTMENT if row[:record_type] == "adjustment"

    if row[:record_type] == "native"
      return ADJUSTMENT if row[:net_pay].to_d.negative?
      return ZERO_NET if row[:net_pay].to_d.zero?
      return "Direct deposit" if row[:payment_delivery_method] == "direct_deposit"

      return row[:check_number].present? ? "Paper check" : "Paper check · not assigned"
    end

    source = row[:payment_method].to_s.strip
    return "Direct deposit" if source.match?(/\A(?:direct[ _-]?deposit|dd|ach)\z/i)
    return "Paper check" if source.match?(/\A(?:paper[ _-]?check|check|cheque)\z/i)
    return source if source.present?

    row[:check_number].present? ? "Paper check" : "Not recorded"
  end
end
