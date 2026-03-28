# frozen_string_literal: true

class EmployeeLoan < ApplicationRecord
  STATUSES = %w[active paid_off suspended].freeze

  belongs_to :employee
  belongs_to :company
  belongs_to :deduction_type, optional: true
  has_many :loan_transactions, dependent: :destroy

  validates :name, presence: true
  validates :original_amount, presence: true, numericality: { greater_than: 0 }
  validates :current_balance, numericality: { greater_than_or_equal_to: 0 }
  validates :payment_amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }
  scope :paid_off, -> { where(status: "paid_off") }
  scope :for_employee, ->(employee_id) { where(employee_id: employee_id) }

  def active?
    status == "active"
  end

  def paid_off?
    status == "paid_off"
  end

  def record_payment!(amount:, pay_period: nil, payroll_item: nil, date: nil)
    raise ArgumentError, "Payment amount must be positive" unless amount.positive?
    raise ArgumentError, "Loan is not active" unless active?

    actual_payment = [amount, current_balance].min
    balance_before = current_balance

    transaction do
      loan_transactions.create!(
        pay_period: pay_period,
        payroll_item: payroll_item,
        transaction_type: "payment",
        amount: actual_payment,
        balance_before: balance_before,
        balance_after: balance_before - actual_payment,
        transaction_date: date || Date.current
      )

      new_balance = (balance_before - actual_payment).round(2)
      attrs = { current_balance: new_balance }
      attrs[:status] = "paid_off" if new_balance.zero?
      attrs[:paid_off_date] = Date.current if new_balance.zero?
      update!(attrs)
    end

    actual_payment
  end

  def record_addition!(amount:, date: nil, notes: nil)
    raise ArgumentError, "Addition amount must be positive" unless amount.positive?

    balance_before = current_balance

    transaction do
      loan_transactions.create!(
        transaction_type: "addition",
        amount: amount,
        balance_before: balance_before,
        balance_after: balance_before + amount,
        transaction_date: date || Date.current,
        notes: notes
      )

      update!(
        current_balance: (balance_before + amount).round(2),
        status: "active"
      )
    end
  end
end
