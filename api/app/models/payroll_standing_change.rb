# frozen_string_literal: true

# Configuration only: numbers belong to each immutable submission revision.
class PayrollStandingChange < ApplicationRecord
  KINDS = %w[owner_pay extra_hours].freeze
  belongs_to :company
  belongs_to :employee
  belongs_to :employee_wage_rate, optional: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :id) }
  validates :kind, inclusion: { in: KINDS }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :same_company_and_job
  validate :usable_configuration, if: :active?
  after_save :audit_change
  after_destroy :audit_removal

  def availability_error
    return "Employee is missing or belongs to another client. Ask Cornerstone to update this default." unless employee&.company_id == company_id
    return "#{employee.full_name} is #{employee.status}. Ask Cornerstone to update this default or choose Not this period." unless employee.active?
    if kind == "owner_pay"
      return "#{employee.full_name} no longer uses variable salary. Ask Cornerstone to update this default." unless employee.variable_salary?
    elsif !employee.hourly_pay_basis? || !employee_wage_rate&.active? || employee_wage_rate.employee_id != employee_id || employee_wage_rate.rate.nil?
      return "Saved job and rate are missing or inactive for #{employee.full_name}. Ask Cornerstone to update this default or choose Not this period."
    end
    nil
  end

  private

  def same_company_and_job
    errors.add(:employee, "must belong to this client") if employee && employee.company_id != company_id
    if employee_wage_rate && employee_wage_rate.employee_id != employee_id
      errors.add(:employee_wage_rate, "must belong to this employee")
    end
    errors.add(:employee_wage_rate, "is only allowed for extra hours") if kind == "owner_pay" && employee_wage_rate
  end

  def usable_configuration
    # Deactivation remains possible after an employee/job becomes unavailable.
    errors.add(:base, availability_error) if availability_error
  end

  def audit_removal
    AuditLog.record!(company_id: company_id, action: "payroll_standing_changes#destroy", record_type: self.class.name,
      record_id: id, metadata: { previous: attributes.except("created_at", "updated_at") })
  end

  def audit_change
    AuditLog.record!(company_id: company_id, action: "payroll_standing_changes#save", record_type: self.class.name,
      record_id: id, metadata: { changes: saved_changes.except("updated_at", "created_at") })
  end
end
