# frozen_string_literal: true

class EmployeeLoan < ApplicationRecord
  TRACKING_MODES = %w[balance_tracked recurring_no_balance].freeze
  STATUSES = %w[active paid_off suspended stopped].freeze
  BALANCE_SOURCES = %w[new_loan quickbooks statement employee_confirmation other_verified].freeze

  belongs_to :employee
  belongs_to :company
  belongs_to :deduction_type, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :stopped_by, class_name: "User", optional: true
  has_many :loan_transactions, dependent: :destroy
  has_many :employee_payroll_fields, dependent: :nullify

  before_validation :initialize_balance_provenance

  validates :name, presence: true
  validates :tracking_mode, presence: true, inclusion: { in: TRACKING_MODES }
  validates :original_amount, presence: true, numericality: { greater_than: 0 }, if: :balance_tracked?
  validates :current_balance, presence: true, numericality: { greater_than_or_equal_to: 0 }, if: :balance_tracked?
  validates :opening_balance, presence: true, numericality: { greater_than: 0 }, if: :balance_tracked?
  validates :balance_as_of, presence: true, if: :balance_tracked?
  validates :balance_source, presence: true, inclusion: { in: BALANCE_SOURCES }, if: :balance_tracked?
  validates :payment_amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  validate :repayment_scope_is_valid
  validate :tracking_mode_is_immutable, on: :update
  validate :tracking_shape_is_valid
  validate :status_shape_is_valid

  scope :active, -> { where(status: "active") }
  scope :paid_off, -> { where(status: "paid_off") }
  scope :for_employee, ->(employee_id) { where(employee_id: employee_id) }

  def active?
    status == "active"
  end

  def paid_off?
    status == "paid_off"
  end

  def stopped?
    status == "stopped"
  end

  def balance_tracked?
    tracking_mode == "balance_tracked"
  end

  def recurring_no_balance?
    tracking_mode == "recurring_no_balance"
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
        if snapshot["tracking_mode"].present? && snapshot["tracking_mode"] != tracking_mode
          raise ArgumentError, "#{name}: deduction type changed. Unapprove and recalculate this payroll before committing"
        end
        if snapshot["default"] && (snapshot["payment_amount"].to_s != payment_amount.to_s || snapshot["first_deduction_date"].to_s != first_deduction_date.to_s)
          raise ArgumentError, "#{name}: repayment schedule changed. Unapprove and recalculate this payroll before committing"
        end
        unless active? && repayment_schedule_active_on?(transaction_pay_date(pay_period, date)) && scheduled_payment_for(pay_date: transaction_pay_date(pay_period, date), requested_amount: amount) == amount
          raise ArgumentError, "#{name}: loan balance or schedule changed. Unapprove and recalculate this payroll before committing"
        end
      end
      raise ArgumentError, "Loan is not active" unless active?

      actual_payment = balance_tracked? ? [ amount, current_balance ].min : amount
      balance_before = balance_tracked? ? current_balance : nil
      transaction_date = date || Date.current

      loan_transactions.create!(
        pay_period: pay_period,
        payroll_item: payroll_item,
        transaction_type: "payment",
        amount: actual_payment,
        balance_before: balance_before,
        balance_after: balance_tracked? ? balance_before - actual_payment : nil,
        transaction_date: transaction_date,
        notes: notes,
        source: payroll_item.present? ? "payroll" : "manual",
        recorded_by: recorded_by
      )

      if balance_tracked?
        new_balance = (balance_before - actual_payment).round(2)
        attrs = { current_balance: new_balance }
        attrs[:status] = "paid_off" if new_balance.zero?
        attrs[:paid_off_date] = transaction_date if new_balance.zero?
        update!(attrs)
      end

      actual_payment
    end
  end

  def mark_paid_off!(date: nil, notes: nil, recorded_by: nil)
    with_lock do
      raise ArgumentError, "A recurring deduction without a balance should be stopped, not marked paid off" unless balance_tracked?
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
      raise ArgumentError, "Stopped deductions cannot be paused" if stopped?
      raise ArgumentError, "Loan is already suspended" if status == "suspended"

      update!(status: "suspended", notes: append_note(notes))
    end
  end

  def reactivate!(notes: nil)
    with_lock do
      raise ArgumentError, "Paid-off loans cannot be reactivated" if paid_off?
      raise ArgumentError, "Stopped deductions cannot be reactivated; create a new authorized schedule" if stopped?
      raise ArgumentError, "Loan is already active" if active?

      update!(status: "active", notes: append_note(notes))
    end
  end

  def stop!(actor:, reason:)
    with_lock do
      raise ArgumentError, "Only recurring deductions without a balance can be stopped" unless recurring_no_balance?
      raise ArgumentError, "Paid-off loans are already closed" if paid_off?
      raise ArgumentError, "Loan deduction is already stopped" if stopped?
      raise ArgumentError, "Enter why this deduction is being stopped" if reason.to_s.strip.blank?

      update!(
        status: "stopped",
        stopped_at: Time.current,
        stopped_by: actor,
        notes: append_note("Stopped: #{reason.to_s.strip}")
      )
    end
  end

  def record_addition!(amount:, date: nil, notes: nil, recorded_by: nil)
    raise ArgumentError, "Addition amount must be positive" unless amount.positive?
    raise ArgumentError, "A recurring deduction without a balance cannot receive a loan advance" unless balance_tracked?

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

    requested = requested_amount.to_d.round(2)
    return requested if recurring_no_balance?

    [ requested, current_balance ].min.round(2)
  end

  def reverse_payroll_payment!(payment, actor:, reason:)
    with_lock do
      payment.reload
      return if payment.reversal
      raise ArgumentError, "Payment does not belong to this loan" unless payment.employee_loan_id == id && payment.source == "payroll"

      new_balance = balance_tracked? ? current_balance + payment.amount : nil
      loan_transactions.create!(
        transaction_type: "adjustment", source: "payroll", amount: payment.amount,
        balance_before: current_balance, balance_after: new_balance,
        transaction_date: Date.current, payroll_item: payment.payroll_item,
        pay_period: payment.pay_period, reverses_transaction: payment,
        recorded_by: actor, notes: "Payroll void: #{reason}"
      )
      if balance_tracked?
        update!(current_balance: new_balance, status: paid_off? ? "active" : status, paid_off_date: nil)
      end
    end
  end

  # A stopped field assignment must not hide a separate legacy schedule.
  # Calculation and commit use the same eligibility rule for either source.
  def repayment_schedule_active_on?(pay_date)
    field_schedule_active = employee_payroll_fields.active.effective_on(pay_date).joins(:payroll_field_definition)
      .where(payroll_field_definitions: { active: true }).exists?
    legacy_schedule_active = deduction_type&.active? &&
      employee.employee_deductions.active.exists?(deduction_type_id: deduction_type_id)

    field_schedule_active || legacy_schedule_active == true
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

  def tracking_mode_is_immutable
    return unless will_save_change_to_tracking_mode?

    errors.add(:tracking_mode, "cannot be changed after the deduction is created")
  end

  def tracking_shape_is_valid
    if recurring_no_balance?
      balance_fields = [ original_amount, opening_balance, current_balance, balance_as_of, balance_source ]
      errors.add(:base, "A recurring deduction without a balance cannot store loan balance values") if balance_fields.any?(&:present?)
      errors.add(:principal_amount_known, "must be false when no balance is tracked") if principal_amount_known?
      errors.add(:payment_amount, "is required for a recurring deduction") unless payment_amount&.positive?
      errors.add(:first_deduction_date, "is required for a recurring deduction") if first_deduction_date.blank?
    elsif balance_tracked?
      errors.add(:status, "cannot be stopped; suspend it or mark it paid off") if stopped?
    end
  end

  def status_shape_is_valid
    if stopped?
      errors.add(:stopped_at, "is required") if stopped_at.blank?
    elsif stopped_at.present? || stopped_by.present?
      errors.add(:base, "Stop evidence is only valid for a stopped deduction")
    end

    errors.add(:status, "paid off is only valid for a balance-tracked loan") if paid_off? && !balance_tracked?
  end

  def transaction_pay_date(pay_period, date)
    pay_period&.pay_date || date || Date.current
  end

  def initialize_balance_provenance
    if recurring_no_balance?
      self.original_amount = nil
      self.opening_balance = nil
      self.current_balance = nil
      self.balance_as_of = nil
      self.balance_source = nil
      self.principal_amount_known = false
      return
    end

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
