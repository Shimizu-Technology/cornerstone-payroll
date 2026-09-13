# frozen_string_literal: true

# Prevents a payroll correction from replacing or reversing liability journal
# entries while an active outgoing payment still points at those entries.
# Staff must void a paid payment, or void/delete a prepared payment, first so
# both the liability and payment histories remain explicit and explainable.
class PayrollLiabilityPaymentGuard
  def self.ensure_clear!(pay_period:, error_class:, action:)
    payments = NonEmployeeCheck.active
      .joins(payroll_liability_check_allocations: { payroll_liability_entry: :payroll_liability_posting })
      .where(payroll_liability_postings: { pay_period_id: pay_period.id })
      .distinct
      .order(:id)
      .to_a
    return if payments.empty?

    references = payments.map do |payment|
      label = payment.payment_method == "check" ? "check #{payment.check_number}" : payment.payment_method.upcase
      "#{label} to #{payment.payable_to} (#{payment.check_status})"
    end.join(", ")

    raise error_class,
          "Void or delete the linked liability payment before #{action}: #{references}"
  end
end
