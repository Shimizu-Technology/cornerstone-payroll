# frozen_string_literal: true

module AirePayrollCockpit
  class Presenter
    def initialize(source:)
      @source = source
    end

    def overview(period_payload:, employees_payload:, command_access:, routing_options: [])
      {
        payroll_period: required(period_payload, "payroll_period"),
        readiness: required(period_payload, "readiness"),
        finalized_batch: period_payload["finalized_batch"],
        processing_history: period_payload.fetch("processing_history", []),
        carryovers: period_payload.fetch("carryovers", {}),
        employees: employees(employees_payload).fetch(:employees),
        employee_pagination: required(employees_payload, "pagination"),
        command_access: command_access,
        routing_options: routing_options
      }
    end

    def employees(payload)
      {
        employees: payload.fetch("employees", []).map { |employee| decorate_employee(employee) },
        pagination: required(payload, "pagination")
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

    def settlement_cases(payload)
      payload.merge(
        "settlement_cases" => payload.fetch("settlement_cases", []).map { |settlement_case| decorate_settlement_case(settlement_case) }
      )
    end

    def manual_review(payload)
      payload.merge(
        "employees" => payload.fetch("employees", []).map do |employee|
          employee.merge(
            "cornerstone" => mapping_payload(
              employee["source_user_uuid"] || employee["payroll_integration_id"],
              source_user_id: employee["source_user_id"],
              required: true
            )
          )
        end,
        "exclusions" => payload.fetch("exclusions", []).map do |exclusion|
          exclusion.merge(
            "cornerstone" => mapping_payload(
              exclusion["source_user_uuid"] || exclusion["payroll_integration_id"],
              source_user_id: exclusion["source_user_id"],
              required: true
            )
          )
        end,
        "manual_allocations" => payload.fetch("manual_allocations", []).map do |allocation|
          allocation.merge(
            "cornerstone" => mapping_payload(allocation["source_user_uuid"], required: true)
          )
        end,
        "payment_attestations" => payload.fetch("payment_attestations", []).map do |attestation|
          attestation.merge(
            "cornerstone" => mapping_payload(attestation["source_user_uuid"], required: true)
          )
        end
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
          source_user_id: employee["id"],
          required: employee["time_tracking_enabled"] != false
        )
      )
    end

    def decorate_entry(entry)
      employee = entry.fetch("employee", {})
      entry.merge(
        "employee" => employee.merge("cornerstone" => mapping_payload(employee["payroll_integration_id"], source_user_id: employee["id"], required: true))
      )
    end

    def decorate_leave(request_record)
      employee = request_record.fetch("employee", {})
      request_record.merge(
        "employee" => employee.merge("cornerstone" => mapping_payload(employee["payroll_integration_id"], source_user_id: employee["id"], required: true))
      )
    end

    def decorate_settlement_case(settlement_case)
      employee = settlement_case.fetch("employee", {})
      settlement_case.merge(
        "employee" => employee.merge("cornerstone" => mapping_payload(employee["payroll_integration_id"], source_user_id: employee["id"], required: true))
      )
    end

    def mapping_payload(source_user_uuid, required:, source_user_id: nil)
      mapping = mappings_by_uuid[TimeTrackingEmployeeMapping.normalize_uuid(source_user_uuid)]
      if mapping.nil? && source_user_id.present? && (legacy = legacy_mappings_by_id[source_user_id.to_s])
        return {
          "status" => "needs_verification",
          "employee_id" => legacy.employee_id,
          "employee_name" => legacy.employee.full_name,
          "employee_active" => legacy.employee.active?
        }
      end
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

    def legacy_mappings_by_id
      @legacy_mappings_by_id ||= @source.time_tracking_employee_mappings
        .includes(:employee)
        .where(source_user_uuid: nil)
        .index_by { |mapping| mapping.source_user_id.to_s }
    end
  end
end
