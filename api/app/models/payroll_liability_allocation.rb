# frozen_string_literal: true

class PayrollLiabilityAllocation < ApplicationRecord
  belongs_to :payroll_liability_payment, inverse_of: :allocations
  belongs_to :payroll_liability_entry
  belongs_to :company

  validates :amount, numericality: { other_than: 0 }
  validates :payroll_liability_entry_id, uniqueness: { scope: :payroll_liability_payment_id }
  validate :context_is_consistent

  def readonly?
    persisted?
  end

  private

  def context_is_consistent
    return if payroll_liability_payment.blank? || payroll_liability_entry.blank? || company_id.blank?

    payment = payroll_liability_payment
    entry = payroll_liability_entry
    errors.add(:company, "must match the payment and liability entry") unless company_id == payment.company_id && company_id == entry.company_id
    errors.add(:payroll_liability_entry, "must belong to the payment pay period") if entry.payroll_liability_posting.pay_period_id != payment.pay_period_id
    unless entry.category == payment.category && entry.authority == payment.authority
      errors.add(:payroll_liability_entry, "must match the payment category and recipient")
    end
    if payment.reversal? != amount.negative?
      errors.add(:amount, "must have the same direction as the payment")
    end
  end
end
