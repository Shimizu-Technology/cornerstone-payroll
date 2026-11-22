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
    AuditLog.record!(user: Current.user, actor: Current.actor || AuditActor.system_job(self.class.name),
      company_id: pay_period.company_id, action: "payroll_entry_resolutions##{destroyed? ? 'destroy' : 'save'}",
      record_type: "PayPeriod", record_id: pay_period_id, subject_name: employee&.full_name,
      metadata: { resolution: attributes, changes: saved_changes, pay_period_status: pay_period.status,
        employee_name: employee&.full_name, field_kind: payroll_standing_change&.kind, field_label: payroll_standing_change&.label.presence,
        client_review_revision: pay_period.payroll_review_packages.current.maximum(:revision) })
  end
end
