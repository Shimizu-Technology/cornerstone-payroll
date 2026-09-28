# frozen_string_literal: true

class ExpensePaymentService
  def self.record!(expense:, actor:, amount:, paid_on:, payment_method:, reference_number: nil, notes: nil)
    Expense.transaction do
      expense = Expense.lock.find(expense.id)
      raise ArgumentError, "Voided expenses cannot receive payments" if expense.voided?

      amount = BigDecimal(amount.to_s)
      raise ArgumentError, "Payment must be a positive amount in cents" unless amount.positive? && amount == amount.round(2)
      raise ArgumentError, "Payment exceeds the remaining balance" if amount > expense.balance_due

      expense.expense_payments.create!(
        organization: expense.organization,
        amount: amount,
        paid_on: paid_on,
        payment_method: payment_method,
        reference_number: reference_number,
        notes: notes,
        recorded_by: actor
      )
    end
  end

  def self.reverse!(payment:, actor:, reason:)
    raise ArgumentError, "A reversal reason is required" if reason.blank?

    Expense.transaction do
      expense = Expense.lock.find(payment.expense_id)
      payment = expense.expense_payments.lock.find(payment.id)
      raise ArgumentError, "Payment has already been reversed" if payment.reversed?
      raise ArgumentError, "Voided expenses cannot have payment changes" if expense.voided?

      payment.update!(reversed_at: Time.current, reversed_by: actor, reversal_reason: reason)
      payment
    end
  end
end
