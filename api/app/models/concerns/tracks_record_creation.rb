# frozen_string_literal: true

# Model callbacks run inside the creating transaction, including imports and copies.
module TracksRecordCreation
  extend ActiveSupport::Concern

  TYPES = { "Company" => "companies", "Employee" => "employees", "PayPeriod" => "pay_periods" }.freeze

  included do
    before_create :assign_record_creator
    after_create :audit_record_creation
  end

  private

  def record_creation_actor
    return Current.user if Current.user
    return migration_rehearsal_created_by if is_a?(Company) && migration_rehearsal_created_by
    return company.migration_rehearsal_created_by if !is_a?(Company) && company&.test_workspace? && company.migration_rehearsal_created_by
    return unless has_attribute?(:created_by_id)

    User.find_by(id: self[:created_by_id])
  end

  def assign_record_creator
    return unless TYPES.key?(self.class.name) && has_attribute?(:created_by_id)

    self[:created_by_id] = record_creation_actor&.id
  end

  def audit_record_creation
    type = TYPES[self.class.name]
    return unless type

    actor = Current.user || record_creation_actor
    company = is_a?(Company) ? self : try(:company)
    metadata = if is_a?(Company) && test_workspace?
      { source_company_id: migration_source_company_id, source_company_name: migration_source_company&.name,
        copy_mode: test_workspace_manifest["copy_mode"], purpose: test_workspace_purpose }
    else
      {}
    end
    AuditLog.record!(user: actor, company_id: company&.id, organization_id: try(:organization_id) || company&.organization_id,
      action: "#{type}#create", record_type: type, record_id: id,
      subject_name: try(:name).presence || try(:full_name), metadata: metadata)
  end
end
