# frozen_string_literal: true

class PayrollItem < ApplicationRecord
  belongs_to :pay_period
  belongs_to :employee

  validates :employment_type, inclusion: { in: %w[hourly salary] }
  validates :pay_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }

  # Validate that each employee only appears once per pay period
  validates :employee_id, uniqueness: { scope: :pay_period_id }

  delegate :company, to: :pay_period
  delegate :full_name, to: :employee, prefix: true

  def total_hours
    hours_worked.to_f + overtime_hours.to_f + holiday_hours.to_f + pto_hours.to_f
  end

  def overtime_pay
    return 0 unless hourly?

    overtime_hours.to_f * pay_rate * 1.5
  end

  def regular_pay
    return 0 unless hourly?

    hours_worked.to_f * pay_rate
  end

  def hourly?
    employment_type == "hourly"
  end

  def salary?
    employment_type == "salary"
  end

  # Calculate and store all values
  def calculate!
    calculator = PayrollCalculator.for(employee, self)
    calculator.calculate
    save!
  end
end
