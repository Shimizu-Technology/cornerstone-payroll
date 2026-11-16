# frozen_string_literal: true

class PayrollEntryResolution < ApplicationRecord
  belongs_to :pay_period
  belongs_to :employee
  belongs_to :payroll_standing_change, optional: true
  validates :note, length: { maximum: 500 }
  validate :matching_scope
  after_save :audit_resolution
  after_destroy :audit_resolution

  private

  def matching_scope
    errors.add(:employee, "must belong to this client") unless employee&.company_id == pay_period&.company_id
    return unless payroll_standing_change

    field = payroll_standing_change
    unless field.company_id == pay_period&.company_id && field.employee_id == employee_id && field.active? && field.allow_none?
      errors.add(:base, "This field cannot be marked None this period")
    end
  end

  def audit_resolution
    AuditLog.record!(company_id: pay_period.company_id, action: "payroll_entry_resolutions##{destroyed? ? 'destroy' : 'save'}",
      record_type: "PayPeriod", record_id: pay_period_id, metadata: { resolution: attributes, changes: saved_changes })
  end
end
