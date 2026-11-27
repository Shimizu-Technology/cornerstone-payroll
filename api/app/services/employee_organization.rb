# frozen_string_literal: true

module EmployeeOrganization
  FIELDS = %w[department_id job_title company_job_role_id].freeze

  def self.assign!(employee, attributes, actor:)
    before = employee.slice(*FIELDS)
    employee.update!(attributes)
    after = employee.slice(*FIELDS)
    audit!(employee, actor: actor, before: before, after: after) if before != after
  end

  def self.audit!(record, actor:, before:, after:)
    fields = (before.keys | after.keys).select { |key| before[key] != after[key] }
    AuditLog.record!(
      user: actor, actor: (AuditActor.system_job("Wage-rate department assignment") unless actor), company_id: record.company_id, organization_id: record.company.organization_id,
      action: "employee_organization#update", record_type: record.class.name, record_id: record.id,
      subject_name: AuditRecordSnapshot.subject_name(record),
      metadata: { changed_fields: fields, before_values: before.slice(*fields), after_values: after.slice(*fields) }
    )
  end
end
