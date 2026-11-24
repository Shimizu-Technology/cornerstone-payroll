# frozen_string_literal: true

class EmployeeContactChangeToConfirm < ApplicationRecord
  self.table_name = "employee_contact_changes_to_confirm"

  FIELDS = {
    "contact" => %w[email phone emergency_contacts].freeze,
    "address" => %w[address_line1 address_line2 city state zip].freeze
  }.freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :changed_by, class_name: "User", optional: true
  belongs_to :confirmed_by, class_name: "User", optional: true

  scope :unconfirmed, -> { where(confirmed_at: nil) }
  scope :recent_first, -> { order(id: :desc) }

  def self.unconfirmed_count(company)
    return unless CompanyFeatures.for(company).employee_portal_feature?(:profile_requests)

    where(company_id: company.id).unconfirmed.count
  end

  # Called in the transaction that applies the employee change. The same entry
  # powers the client activity view and the payroll confirmation queue.
  def self.record!(employee:, actor:, before_values:, after_values:, reviewer: nil)
    return if employee.portal_pending_approval?

    before_values = before_values.stringify_keys.transform_values(&:presence)
    after_values = after_values.stringify_keys.transform_values(&:presence)
    FIELDS.each do |kind, fields|
      changed = after_values.slice(*fields).reject { |field, value| before_values[field] == value }
      next if changed.empty?

      entry = create!(
        company_id: employee.company_id, employee: employee, changed_by: actor, change_kind: kind,
        before_values: changed.keys.index_with { |field| before_values[field] }, after_values: changed
      )
      PortalNotifications.employee_contact_changed!(entry, actor: reviewer || actor)
    end
  end

  def as_activity_json(include_confirmation: false)
    data = {
      id: id, employee_id: employee_id, employee_name: employee.full_name, changed_by_name: changed_by&.name,
      change_kind: change_kind, before_values: before_values, after_values: after_values, created_at: created_at
    }
    if include_confirmation
      data.merge!(confirmed_at: confirmed_at, confirmed_by_name: confirmed_by&.name)
    end
    data
  end
end
