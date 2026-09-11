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

  validate :repayment_scope_is_valid

  scope :active, -> { where(status: "active") }
  scope :paid_off, -> { where(status: "paid_off") }
  scope :for_employee, ->(employee_id) { where(employee_id: employee_id) }

  def active?
    status == "active"
  end

  def paid_off?
    status == "paid_off"
  end

  def record_payment!(amount:, pay_period: nil, payroll_item: nil, date: nil, notes: nil, recorded_by: nil, schedule_snapshot: {})
    raise ArgumentError, "Payment amount must be positive" unless amount.positive?

    with_lock do
      if payroll_item
        existing = loan_transactions.payments.find_by(payroll_item_id: payroll_item.id)
        if existing && !existing.reversal
          raise ArgumentError, "Payroll loan payment differs from its recorded amount" unless existing.amount == amount
          return existing.amount
        end
        unless payroll_item.employee_id == employee_id && payroll_item.company_id == company_id
          raise ArgumentError, "Payroll loan payment belongs to another employee or client"
        end
        raise ArgumentError, "Reversed payroll payments cannot be reapplied; create a correction payroll" if existing
        snapshot = schedule_snapshot.to_h.stringify_keys
        if snapshot["default"] && (snapshot["payment_amount"].to_s != payment_amount.to_s || snapshot["first_deduction_date"].to_s != first_deduction_date.to_s)
          raise ArgumentError, "#{name}: repayment schedule changed. Unapprove and recalculate this payroll before committing"
        end
        unless active? && amount <= current_balance && repayment_schedule_active_on?(transaction_pay_date(pay_period, date)) && scheduled_payment_for(pay_date: transaction_pay_date(pay_period, date), requested_amount: amount) == amount
          raise ArgumentError, "#{name}: loan balance or schedule changed. Unapprove and recalculate this payroll before committing"
        end
      end
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
        status: "active",
        paid_off_date: nil
      )
    end
  end

  # Calculation is read-only; the ledger moves only when payroll is committed.
  def scheduled_payment_for(pay_date:, requested_amount:)
    return 0.to_d unless active?
    return 0.to_d if first_deduction_date.present? && pay_date < first_deduction_date
    return 0.to_d if balance_as_of.present? && pay_date < balance_as_of

    [ requested_amount.to_d, current_balance ].min.round(2)
  end

  def reverse_payroll_payment!(payment, actor:, reason:)
    with_lock do
      payment.reload
      return if payment.reversal
      raise ArgumentError, "Payment does not belong to this loan" unless payment.employee_loan_id == id && payment.source == "payroll"

      new_balance = current_balance + payment.amount
      loan_transactions.create!(
        transaction_type: "adjustment", source: "payroll", amount: payment.amount,
        balance_before: current_balance, balance_after: new_balance,
        transaction_date: Date.current, payroll_item: payment.payroll_item,
        pay_period: payment.pay_period, reverses_transaction: payment,
        recorded_by: actor, notes: "Payroll void: #{reason}"
      )
      update!(current_balance: new_balance, status: paid_off? ? "active" : status, paid_off_date: nil)
    end
  end

  private

  def repayment_scope_is_valid
    errors.add(:company, "must match the employee's client") if employee && company_id != employee.company_id
    if deduction_type && (deduction_type.company_id != company_id || !deduction_type.loan? || !deduction_type.post_tax?)
      errors.add(:deduction_type, "must be a post-tax loan deduction for this client")
    end
    if deduction_type_id && self.class.where(employee_id: employee_id, deduction_type_id: deduction_type_id).where.not(id: id).exists?
      errors.add(:deduction_type, "already has a loan balance; use a separate repayment schedule")
    end
    if first_deduction_date && balance_as_of && first_deduction_date < balance_as_of
      errors.add(:first_deduction_date, "must be on or after the verified balance date")
    end
  end

  def repayment_schedule_active_on?(pay_date)
    if employee_payroll_fields.exists?
      employee_payroll_fields.active.effective_on(pay_date).joins(:payroll_field_definition)
        .where(payroll_field_definitions: { active: true }).exists?
    elsif deduction_type_id
      deduction_type&.active? && employee.employee_deductions.active.exists?(deduction_type_id: deduction_type_id)
    else
      false
    end
  end

  def transaction_pay_date(pay_period, date)
    pay_period&.pay_date || date || Date.current
  end

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
