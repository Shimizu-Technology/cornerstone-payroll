# frozen_string_literal: true

class EmployeePayrollField < ApplicationRecord
  belongs_to :employee
  belongs_to :payroll_field_definition
  belongs_to :employee_loan, optional: true

  validates :payroll_field_definition_id, uniqueness: { scope: :employee_id }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :percentage, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :field_belongs_to_employee_company
  validate :date_range_is_valid

  scope :active, -> { where(active: true) }
  scope :effective_on, ->(date) {
    where("start_date IS NULL OR start_date <= ?", date)
      .where("end_date IS NULL OR end_date >= ?", date)
  }

  delegate :name, :kind, :tax_treatment, :category, :amount_type, to: :payroll_field_definition

  def effective_amount_for(gross_pay)
    if payroll_field_definition.amount_type == "percentage"
      percent = percentage.presence || payroll_field_definition.default_percentage || 0
      (gross_pay.to_d * (percent.to_d / 100)).round(2)
    else
      (amount.presence || payroll_field_definition.default_amount || 0).to_d.round(2)
    end
  end

  private

  def field_belongs_to_employee_company
    return if employee.blank? || payroll_field_definition.blank?

    if payroll_field_definition.company_id != employee.company_id
      errors.add(:payroll_field_definition, "must belong to the employee's company")
    end
  end

  def date_range_is_valid
    return if start_date.blank? || end_date.blank? || end_date >= start_date

    errors.add(:end_date, "must be on or after the start date")
  end
end
