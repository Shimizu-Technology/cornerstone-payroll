# frozen_string_literal: true

# New payroll rounds each payable line once, then sums those cents. A missing
# policy in a historical calculation context retains the pre-deploy gross rule.
module PayrollEarningsRounding
  POLICY = "saved_lines_v1"
  NON_TAXABLE_CATEGORIES = %w[non_taxable reimbursement].freeze
  HISTORICAL_LABEL = "Historical earnings rounding"
  MESSAGE = "Saved earnings do not reconcile to gross and net pay. Recalculate this payroll before approval or commitment."

  def self.line_amount(amount)
    BigDecimal(amount.to_s).round(2, :half_up)
  end

  def self.taxable_total(item)
    item.payroll_item_earnings.reject { |row| row.category.in?(NON_TAXABLE_CATEGORIES) }.sum(0.to_d, &:amount)
  end

  def self.validate!(item)
    # Historical committed amounts are evidence, never rewritten or reinterpreted
    # by the new calculation boundary. Corrections reconcile their own deltas.
    return if item.pay_period.committed?
    return unless item.calculation_context_snapshot["earnings_rounding"] == POLICY

    item.payroll_item_earnings.reload
    other = item.payroll_item_earnings.select { |row| row.category.in?(NON_TAXABLE_CATEGORIES) }.sum(0.to_d, &:amount)
    unless taxable_total(item) == item.gross_pay.to_d &&
        item.gross_pay.to_d + other - item.total_deductions.to_d == item.net_pay.to_d
      raise ArgumentError, MESSAGE
    end
  end
end
