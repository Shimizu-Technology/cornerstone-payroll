# frozen_string_literal: true

module TimeTracking
  class EmployeeMappingService
    def initialize(company:, source:, employee:, source_employee:, actor:)
      @company = company
      @source = source
      @employee = employee
      @source_employee = source_employee
      @actor = actor
    end

    def confirm!
      validate!

      mapping = TimeTrackingEmployeeMapping.transaction do
        source.lock!
        record = TimeTrackingEmployeeMapping.resolve_source_identity!(
          company: company,
          source: source,
          source_user_id: source_user_id,
          source_user_uuid: source_user_uuid
        ) || TimeTrackingEmployeeMapping.new(
          company: company,
          time_tracking_source: source,
          source_user_id: source_user_id
        )
        previous_employee_id = record.employee_id
        record.update!(
          employee: employee,
          source_user_id: source_user_id,
          source_user_uuid: source_user_uuid,
          source_email: source_employee["email"],
          source_display_name: source_employee["full_name"] || source_employee["display_name"]
        )
        record_audit!(record, previous_employee_id)
        record
      end

      mapping
    rescue ActiveRecord::RecordNotUnique
      raise TimeTrackingEmployeeMapping::IdentityConflict,
            "That AIRE or payroll employee was linked by another update. Refresh the team list and review the current link."
    end

    private

    attr_reader :company, :source, :employee, :source_employee, :actor

    def validate!
      raise ArgumentError, "Time-tracking source does not belong to this company" unless source.company_id == company.id
      raise ArgumentError, "Payroll employee does not belong to this company" unless employee.company_id == company.id
      raise ArgumentError, "Choose an active payroll employee" unless employee.active?
      raise ArgumentError, "AIRE employee identity is missing" if source_user_id.blank? || source_user_uuid.blank?
    end

    def source_user_id
      source_employee.fetch("id").to_s
    end

    def source_user_uuid
      @source_user_uuid ||= TimeTrackingEmployeeMapping.normalize_uuid(source_employee["payroll_integration_id"])
    end

    def record_audit!(mapping, previous_employee_id)
      AuditLog.record!(
        user: actor,
        company_id: company.id,
        action: "time_tracking_employee_mapping#confirmed",
        record_type: "TimeTrackingEmployeeMapping",
        record_id: mapping.id,
        subject_name: source_employee["full_name"],
        event_category: "payroll",
        metadata: {
          time_tracking_source_id: source.id,
          source_user_id: source_user_id,
          source_user_uuid: source_user_uuid,
          previous_employee_id: previous_employee_id,
          employee_id: employee.id,
          employee_name: employee.full_name
        }.compact
      )
    end
  end
end
