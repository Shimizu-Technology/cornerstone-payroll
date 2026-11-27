# frozen_string_literal: true

# Presentation only: use the payroll snapshot, never today's employee default
# to reinterpret a committed paycheck or a retained historical source. Every
# payment wording (pay history, both pay stub copies, reports, the web app)
# comes from here.
class PayrollPaymentLabel
  ZERO_NET = "$0 net · earnings statement only"
  ADJUSTMENT = "Adjustment — no payment issued"
  DIRECT_DEPOSIT = "Direct deposit"
  NO_PAYMENT = "Earnings statement only - no payment issued"
  # The paper itself was retired; the pay is still owed (D-10). The pay run
  # and the employee app say the same.
  VOIDED_CHECK = "Paper check · voided"

  # The Payment line a pay stub prints, on the employee's and the client's
  # copy alike. It is part of a posted stub's fingerprint: changing this text
  # re-posts frozen stubs.
  def self.statement_line(item)
    if !item.net_pay.to_d.positive?
      [ NO_PAYMENT, item.check_number.presence ].compact.join(" · ")
    elsif item.effective_payment_delivery_method == "direct_deposit"
      DIRECT_DEPOSIT
    else
      "Check ##{item.check_number}"
    end
  end

  def self.for(item)
    return ADJUSTMENT if item.net_pay.to_d.negative?
    return ZERO_NET if item.net_pay.to_d.zero?
    return DIRECT_DEPOSIT if item.effective_payment_delivery_method == "direct_deposit"
    return VOIDED_CHECK if item.voided?

    item.check_number.present? ? "Paper check" : "Paper check · not assigned"
  end

  def self.history_row(row)
    return row[:payment_method_label] if row[:payment_method_label].present?
    return ADJUSTMENT if row[:record_type] == "adjustment"

    if row[:record_type] == "native"
      return ADJUSTMENT if row[:net_pay].to_d.negative?
      return ZERO_NET if row[:net_pay].to_d.zero?
      return DIRECT_DEPOSIT if row[:payment_delivery_method] == "direct_deposit"

      return row[:check_number].present? ? "Paper check" : "Paper check · not assigned"
    end

    source = row[:payment_method].to_s.strip
    return DIRECT_DEPOSIT if source.match?(/\A(?:direct[ _-]?deposit|dd|ach)\z/i)
    return "Paper check" if source.match?(/\A(?:paper[ _-]?check|check|cheque)\z/i)
    return source if source.present?

    row[:check_number].present? ? "Paper check" : "Not recorded"
  end
end
