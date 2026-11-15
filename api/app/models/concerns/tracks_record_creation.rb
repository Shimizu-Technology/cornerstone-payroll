# frozen_string_literal: true

# Model callbacks run inside the creating transaction, including imports and copies.
# Only creations by a signed-in person are audited here: copies, rehearsals and
# background jobs keep a creator but rely on their own summary audit rows.
module TracksRecordCreation
  extend ActiveSupport::Concern

  TYPES = { "Company" => "companies", "Employee" => "employees", "PayPeriod" => "pay_periods" }.freeze

  included do
    before_create :assign_record_creator
    after_create :audit_record_creation
    after_rollback :restore_domain_audit_marker
    after_commit :forget_domain_audit_marker
  end

  private

  def record_creation_actor
    return Current.user if Current.user
    return migration_rehearsal_created_by if is_a?(Company) && migration_rehearsal_created_by
    company.migration_rehearsal_created_by if !is_a?(Company) && company&.test_workspace?
  end

  def assign_record_creator
    return unless TYPES.key?(self.class.name) && has_attribute?(:created_by_id)

    self[:created_by_id] ||= record_creation_actor&.id
  end

  # Test workspaces write their own "test_workspace#create" row with the copy
  # details, and the employees and pay periods copied into them are covered by it.
  def copied_or_test_workspace_record?
    return test_workspace? if is_a?(Company)

    try(:test_workspace_source_employee_id).present? || try(:test_workspace_role) == "baseline"
  end

  def audit_record_creation
    type = TYPES[self.class.name]
    return unless type && Current.user
    return if copied_or_test_workspace_record?

    company = is_a?(Company) ? self : try(:company)
    @domain_audit_marker_before_creation = Current.domain_audit_recorded
    AuditLog.record!(user: Current.user, company_id: company&.id, organization_id: try(:organization_id) || company&.organization_id,
      action: "#{type}#create", record_type: type, record_id: id,
      subject_name: try(:name).presence || try(:full_name))
  end

  # A rolled-back creation leaves no audit row, so the request-level audit
  # must not be suppressed on its account.
  def restore_domain_audit_marker
    return unless defined?(@domain_audit_marker_before_creation)

    Current.domain_audit_recorded = @domain_audit_marker_before_creation
    forget_domain_audit_marker
  end

  def forget_domain_audit_marker
    remove_instance_variable(:@domain_audit_marker_before_creation) if defined?(@domain_audit_marker_before_creation)
  end
end
