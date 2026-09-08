# frozen_string_literal: true

class EmployeeLoan < ApplicationRecord
  STATUSES = %w[active paid_off suspended].freeze
  BALANCE_SOURCES = %w[new_loan quickbooks statement employee_confirmation other_verified].freeze

  belongs_to :employee
  belongs_to :company
  belongs_to :deduction_type, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  has_many :loan_transactions, dependent: :destroy
  has_many :employee_payroll_fields, dependent: :nullify

  before_validation :initialize_balance_provenance

  validates :name, presence: true
  validates :original_amount, presence: true, numericality: { greater_than: 0 }
  validates :current_balance, numericality: { greater_than_or_equal_to: 0 }
  validates :opening_balance, presence: true, numericality: { greater_than: 0 }
  validates :balance_as_of, presence: true
  validates :balance_source, presence: true, inclusion: { in: BALANCE_SOURCES }
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

  def record_payment!(amount:, pay_period: nil, payroll_item: nil, date: nil, notes: nil, recorded_by: nil)
    raise ArgumentError, "Payment amount must be positive" unless amount.positive?

    with_lock do
      raise ArgumentError, "Loan is not active" unless active?

      actual_payment = [ amount, current_balance ].min
      balance_before = current_balance
      transaction_date = date || Date.current

      loan_transactions.create!(
        pay_period: pay_period,
        payroll_item: payroll_item,
        transaction_type: "payment",
        amount: actual_payment,
        balance_before: balance_before,
        balance_after: balance_before - actual_payment,
        transaction_date: transaction_date,
        notes: notes,
        source: payroll_item.present? ? "payroll" : "manual",
        recorded_by: recorded_by
      )

      new_balance = (balance_before - actual_payment).round(2)
      attrs = { current_balance: new_balance }
      attrs[:status] = "paid_off" if new_balance.zero?
      attrs[:paid_off_date] = transaction_date if new_balance.zero?
      update!(attrs)

      actual_payment
    end
  end

  def mark_paid_off!(date: nil, notes: nil, recorded_by: nil)
    with_lock do
      raise ArgumentError, "Loan is already paid off" if paid_off?

      transaction_date = date || Date.current
      if current_balance.positive?
        loan_transactions.create!(
          transaction_type: "payment",
          amount: current_balance,
          balance_before: current_balance,
          balance_after: 0,
          transaction_date: transaction_date,
          notes: notes.presence || "Marked paid off",
          source: "manual",
          recorded_by: recorded_by
        )
      end

      update!(current_balance: 0, status: "paid_off", paid_off_date: transaction_date)
    end
  end

  def suspend!(notes: nil)
    with_lock do
      raise ArgumentError, "Paid-off loans cannot be suspended" if paid_off?
      raise ArgumentError, "Loan is already suspended" if status == "suspended"

      update!(status: "suspended", notes: append_note(notes))
    end
  end

  def reactivate!(notes: nil)
    with_lock do
      raise ArgumentError, "Paid-off loans cannot be reactivated" if paid_off?
      raise ArgumentError, "Loan is already active" if active?

      update!(status: "active", notes: append_note(notes))
    end
  end

  def record_addition!(amount:, date: nil, notes: nil, recorded_by: nil)
    raise ArgumentError, "Addition amount must be positive" unless amount.positive?

    with_lock do
      balance_before = current_balance
      loan_transactions.create!(
        transaction_type: "addition",
        amount: amount,
        balance_before: balance_before,
        balance_after: balance_before + amount,
        transaction_date: date || Date.current,
        notes: notes,
        source: "manual",
        recorded_by: recorded_by
      )

      update!(
        current_balance: (balance_before + amount).round(2),
        status: "active"
      )
    end
  end

  private

  def initialize_balance_provenance
    self.opening_balance ||= original_amount
    self.balance_as_of ||= start_date || Date.current
    self.balance_source ||= "new_loan"
  end

  def append_note(note)
    return notes if note.blank?
    return note if notes.blank?

    [ notes, note ].join("\n")
  end
end
