# frozen_string_literal: true

module AirePayrollCockpit
  class Presenter
    def initialize(source:)
      @source = source
    end

    def overview(period_payload:, employees_payload:, command_access:)
      {
        payroll_period: required(period_payload, "payroll_period"),
        readiness: required(period_payload, "readiness"),
        finalized_batch: period_payload["finalized_batch"],
        processing_history: period_payload.fetch("processing_history", []),
        carryovers: period_payload.fetch("carryovers", {}),
        employees: employees_payload.fetch("employees", []).map { |employee| decorate_employee(employee) },
        employee_pagination: required(employees_payload, "pagination"),
        command_access: command_access
      }
    end

    def time_entries(payload)
      payload.merge(
        "time_entries" => payload.fetch("time_entries", []).map { |entry| decorate_entry(entry) }
      )
    end

    def exceptions(payload)
      payload.merge(
        "time_exceptions" => payload.fetch("time_exceptions", []).map { |entry| decorate_entry(entry) },
        "leave_exceptions" => payload.fetch("leave_exceptions", []).map { |request_record| decorate_leave(request_record) }
      )
    end

    private

    def required(payload, key)
      payload.fetch(key) do
        raise TimeTracking::Client::Error.new(
          "#{@source.name} returned an incomplete payroll cockpit payload",
          response_status: 502
        )
      end
    end

    def decorate_employee(employee)
      employee.merge(
        "cornerstone" => mapping_payload(
          employee["payroll_integration_id"],
          required: employee["time_tracking_enabled"] != false
        )
      )
    end

    def decorate_entry(entry)
      employee = entry.fetch("employee", {})
      entry.merge(
        "employee" => employee.merge("cornerstone" => mapping_payload(employee["payroll_integration_id"], required: true))
      )
    end

    def decorate_leave(request_record)
      employee = request_record.fetch("employee", {})
      request_record.merge(
        "employee" => employee.merge("cornerstone" => mapping_payload(employee["payroll_integration_id"], required: true))
      )
    end

    def mapping_payload(source_user_uuid, required:)
      mapping = mappings_by_uuid[TimeTrackingEmployeeMapping.normalize_uuid(source_user_uuid)]
      return { "status" => required ? "unmapped" : "not_required" } unless mapping

      employee = mapping.employee
      {
        "status" => employee.active? ? "mapped" : "inactive",
        "employee_id" => employee.id,
        "employee_name" => employee.full_name
      }
    end

    def mappings_by_uuid
      @mappings_by_uuid ||= @source.time_tracking_employee_mappings
        .includes(:employee)
        .where.not(source_user_uuid: nil)
        .index_by { |mapping| TimeTrackingEmployeeMapping.normalize_uuid(mapping.source_user_uuid) }
    end
  end
end
