# frozen_string_literal: true

module TimeTracking
  class EmployeeMappingService
    class Error < StandardError; end

    def initialize(source:, pay_period: nil, company: nil)
      @company = company || pay_period&.company
      raise ArgumentError, "A payroll company is required" unless @company
      raise ArgumentError, "AIRE source belongs to another company" unless source.company_id == @company.id

      @source = source
    end

    def live_identity!(source_user_id:)
      source_user_id = source_user_id.to_s
      live = TimeTracking::Client.new(@source, delegation: nil).payroll_cockpit_employees(
        page: 1, per_page: 1, employee_id: source_user_id
      ).fetch("employees", []).find { |person| person["id"].to_s == source_user_id }
      raise Error, "AIRE employee was not found; refresh the team list" unless live

      source_uuid = TimeTrackingEmployeeMapping.normalize_uuid(live["payroll_integration_id"])
      raise Error, "AIRE employee has no permanent payroll identity" if source_uuid.blank?

      live
    end

    def link!(source_user_id:, employee_id:, live: nil)
      source_user_id = source_user_id.to_s
      employee = @company.employees.find(employee_id)
      live ||= live_identity!(source_user_id: source_user_id)
      raise Error, "AIRE employee changed; refresh the team list" unless live["id"].to_s == source_user_id

      source_uuid = TimeTrackingEmployeeMapping.normalize_uuid(live["payroll_integration_id"])
      raise Error, "AIRE employee has no permanent payroll identity" if source_uuid.blank?

      mapping = TimeTrackingEmployeeMapping.resolve_source_identity!(
        company: @company, source: @source, source_user_id: source_user_id, source_user_uuid: source_uuid
      )
      if mapping && mapping.employee_id != employee.id
        raise Error, "This AIRE person is already linked to a different payroll employee. Review the existing mapping before changing it."
      end
      mapping.update!(source_user_uuid: source_uuid) if mapping && mapping.source_user_uuid.blank?
      mapping || TimeTrackingEmployeeMapping.create!(
        company: @company, time_tracking_source: @source,
        employee: employee, source_user_id: source_user_id, source_user_uuid: source_uuid
      )
    end
  end
end
