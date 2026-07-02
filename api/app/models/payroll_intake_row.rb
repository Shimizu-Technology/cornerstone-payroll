# frozen_string_literal: true

class PayrollIntakeRow < ApplicationRecord
  STATUSES = %w[pending ready needs_review applied skipped failed].freeze

  belongs_to :payroll_intake_session, inverse_of: :rows
  belongs_to :employee, optional: true
  belongs_to :applied_payroll_item, class_name: "PayrollItem", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :source_employee_name, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :week1_hours, :week2_hours, :regular_hours, :overtime_hours,
            :week1_tips, :week2_tips, :reported_tips, :tips_paid_out, :loan_deduction,
            numericality: { greater_than_or_equal_to: 0 }
  validate :employee_belongs_to_company
  validate :reported_tips_cover_paid_out

  delegate :company, :pay_period, to: :payroll_intake_session

  before_validation :normalize_precision

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
end
