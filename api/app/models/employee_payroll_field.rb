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
  validate :loan_matches_assignment

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

  def loan_matches_assignment
    if persisted? && employee_loan_id_in_database.present?
      errors.add(:employee_loan, "cannot be detached or replaced; suspend this repayment schedule instead") if will_save_change_to_employee_loan_id?
      errors.add(:payroll_field_definition, "cannot be replaced on a linked repayment schedule") if will_save_change_to_payroll_field_definition_id?
    end
    return unless employee_loan

    if employee_loan.employee_id != employee_id || employee_loan.company_id != employee&.company_id
      errors.add(:employee_loan, "must belong to this employee and client")
    end
    unless category == "loan" && tax_treatment == "post_tax_deduction" && amount_type == "fixed"
      errors.add(:employee_loan, "requires a fixed post-tax loan deduction")
    end
    if employee_loan.deduction_type_id.present? || employee_loan.employee_payroll_fields.where.not(id: id).exists?
      errors.add(:employee_loan, "already has a repayment schedule")
    end
  end

  def date_range_is_valid
    return if start_date.blank? || end_date.blank? || end_date >= start_date

    errors.add(:end_date, "must be on or after the start date")
  end
end
