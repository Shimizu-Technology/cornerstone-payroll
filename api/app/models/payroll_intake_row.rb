# frozen_string_literal: true

class PayrollIntakeRow < ApplicationRecord
  STATUSES = %w[pending ready needs_review applied skipped failed].freeze
  DISPOSITIONS = %w[pending included excluded deferred informational].freeze

  belongs_to :payroll_intake_session, inverse_of: :rows
  belongs_to :employee, optional: true
  belongs_to :applied_payroll_item, class_name: "PayrollItem", optional: true
  belongs_to :dispositioned_by, class_name: "User", optional: true
  belongs_to :target_pay_period, class_name: "PayPeriod", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :disposition, inclusion: { in: DISPOSITIONS }
  validates :source_employee_name, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :week1_hours, :week2_hours, :regular_hours, :overtime_hours,
            :week1_tips, :week2_tips, :reported_tips, :tips_paid_out, :loan_deduction,
            numericality: { greater_than_or_equal_to: 0 }
  validate :employee_belongs_to_company
  validate :reported_tips_cover_paid_out
  validate :disposition_is_complete
  validate :target_pay_period_is_valid

  delegate :company, :pay_period, to: :payroll_intake_session

  before_validation :normalize_precision

  scope :in_order, -> { order(:position, :id) }

  def blocking_errors?
    Array(errors_payload).any?
  end

  def errors_payload
    validation_errors || []
  end

  def warnings_payload
    self[:warnings] || []
  end

  def total_hours
    regular_hours.to_f + overtime_hours.to_f
  end

  def included_disposition?
    disposition == "included"
  end

  private

  def normalize_precision
    self.week1_hours = round_decimal(week1_hours)
    self.week2_hours = round_decimal(week2_hours)
    self.regular_hours = round_decimal(regular_hours)
    self.overtime_hours = round_decimal(overtime_hours)
    self.week1_tips = round_currency(week1_tips)
    self.week2_tips = round_currency(week2_tips)
    self.reported_tips = round_currency(reported_tips)
    self.tips_paid_out = round_currency(tips_paid_out)
    self.loan_deduction = round_currency(loan_deduction)
  end

  def round_decimal(value)
    BigDecimal(value.to_s.presence || "0").round(2)
  rescue ArgumentError
    0
  end

  def round_currency(value)
    BigDecimal(value.to_s.presence || "0").round(2)
  rescue ArgumentError
    0
  end

  def employee_belongs_to_company
    return if employee.blank?
    return if employee.company_id == payroll_intake_session.company_id

    errors.add(:employee_id, "must belong to the intake session company")
  end

  def reported_tips_cover_paid_out
    return unless tips_paid_out.to_f.positive?
    return if reported_tips.to_f >= tips_paid_out.to_f

    errors.add(:reported_tips, "must be greater than or equal to tips paid out")
  end

  def disposition_is_complete
    if disposition == "pending"
      errors.add(:dispositioned_at, "must be blank while disposition is pending") if dispositioned_at.present?
      errors.add(:disposition_reason, "must be blank while disposition is pending") if disposition_reason.present?
      errors.add(:target_pay_period, "must be blank while disposition is pending") if target_pay_period.present?
      return
    end

    errors.add(:dispositioned_at, "must be recorded") if dispositioned_at.blank?
    if disposition.in?(%w[excluded deferred informational]) && disposition_reason.to_s.strip.blank?
      errors.add(:disposition_reason, "is required for this outcome")
    end
    if disposition != "deferred" && target_pay_period.present?
      errors.add(:target_pay_period, "is only allowed for deferred rows")
    end
  end

  def target_pay_period_is_valid
    return unless disposition == "deferred"

    if target_pay_period.blank?
      errors.add(:target_pay_period, "is required for deferred rows")
      return
    end
    if target_pay_period.company_id != payroll_intake_session.company_id
      errors.add(:target_pay_period, "must belong to the same company")
    end
    if target_pay_period_id == payroll_intake_session.pay_period_id ||
        target_pay_period.start_date <= payroll_intake_session.pay_period.end_date ||
        !target_pay_period.regular_cycle? || target_pay_period.voided? || target_pay_period.committed?
      errors.add(:target_pay_period, "must be a future editable regular pay period")
    end
  end
end
