# frozen_string_literal: true

# Read-only presentation of corrective rows that retain scalar deltas rather
# than materialized earnings. Never consult today's employee rates or setup.
class SignedCorrectionEarnings
  Line = Struct.new(:label, :amount, :hours, :rate, :source, keyword_init: true)
  TIME_COMPONENTS = [
    [ :hours_worked, "Regular adjustment", 1 ],
    [ :overtime_hours, "Overtime adjustment (1.5x)", 1.5 ],
    [ :holiday_hours, "Holiday adjustment", 1 ],
    [ :pto_hours, "PTO adjustment", 1 ]
  ].freeze

  def self.call(item)
    return unless item.correction_entry?
    return if item.payroll_item_earnings.any? { |earning| earning.category != "non_taxable" }

    gross = item.gross_pay.to_d
    rate = item.pay_rate.to_d
    if item.hourly? && rate.finite? && rate.positive? && item.wage_rate_hours.empty? &&
        [ item.bonus, item.reported_tips, item.service_charge_wages ].all? { |amount| amount.to_d.zero? } &&
        Array(item.custom_earnings).empty?
      lines = TIME_COMPONENTS.filter_map do |field, label, multiplier|
        hours = item.public_send(field).to_d
        next if hours.zero?
        return generic(gross) unless hours.finite?

        applied_rate = rate * multiplier.to_d
        Line.new(label: label, hours: hours, rate: applied_rate,
          amount: (hours * applied_rate).round(2), source: "correction_reference")
      end
      return lines if lines.sum { |line| line.amount } == gross
    end
    generic(gross)
  end

  def self.generic(gross)
    return [] if gross.zero?

    [ Line.new(label: "Taxable earnings adjustment", amount: gross, source: "correction_total") ]
  end
  private_class_method :generic
end
