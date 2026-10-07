# frozen_string_literal: true

# Statements describe payroll activity, not whether there is a payment to issue.
# Callers scope rows to the current company's reportable payroll before using
# this predicate. Hours alone are an input, not evidence of finalized earnings.
class EarningsStatementEligibility
  FINANCIAL_FIELDS = (PayrollItemActivity::REPORTABLE_FIELDS + %i[
    total_additions total_deductions retirement_payment roth_retirement_payment
    insurance_payment loan_payment
  ]).uniq.freeze

  def self.printable?(item)
    return false if item.voided?
    return true if item.check_number.present?
    return true if FINANCIAL_FIELDS.any? { |field| item.public_send(field).to_d.nonzero? }

    # Negative correction amounts and offsetting additions/deductions still
    # belong on a statement even if their resulting gross and net are zero.
    item.payroll_item_earnings.any? { |row| row.amount.to_d.nonzero? } ||
      item.payroll_item_deductions.any? { |row| row.amount.to_d.nonzero? } ||
      item.payroll_item_field_entries.any? { |row| row.active? && row.amount.to_d.nonzero? }
  end
end
