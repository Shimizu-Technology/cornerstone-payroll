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
        entry_processing_history: period_payload.fetch("entry_processing_history", []),
        carryovers: period_payload.fetch("carryovers", {}),
        employees: employees_payload.fetch("employees", []).map { |employee| decorate_employee(employee) },
        employee_pagination: required(employees_payload, "pagination"),
        payroll_employee_options: payroll_employee_options,
        command_access: command_access,
        routing_options: routing_options
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
              required: true
            )
          )
        end,
        "exclusions" => payload.fetch("exclusions", []).map do |exclusion|
          exclusion.merge(
            "cornerstone" => mapping_payload(
              exclusion["source_user_uuid"] || exclusion["payroll_integration_id"],
              required: true
            )
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
          required: employee["time_tracking_enabled"] != false,
          source_employee: employee
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

    def decorate_settlement_case(settlement_case)
      employee = settlement_case.fetch("employee", {})
      settlement_case.merge(
        "employee" => employee.merge("cornerstone" => mapping_payload(employee["payroll_integration_id"], required: true))
      )
    end

    def mapping_payload(source_user_uuid, required:, source_employee: nil)
      mapping = mappings_by_uuid[TimeTrackingEmployeeMapping.normalize_uuid(source_user_uuid)]
      unless mapping
        payload = { "status" => required ? "unmapped" : "not_required" }
        payload["suggestions"] = suggestions_for(source_employee) if required && source_employee
        return payload
      end

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

    def payroll_employee_options
      @payroll_employee_options ||= available_payroll_employees.map do |employee|
        {
          "employee_id" => employee.id,
          "employee_name" => employee.full_name,
          "email" => employee.email,
          "employment_type" => employee.employment_type
        }
      end
    end

    def available_payroll_employees
      @available_payroll_employees ||= begin
        mapped_ids = @source.time_tracking_employee_mappings.where.not(source_user_uuid: nil).pluck(:employee_id)
        Employee.active.where(company_id: @source.company_id).where.not(id: mapped_ids).order(:last_name, :first_name, :id).to_a
      end
    end

    def suggestions_for(source_employee)
      source_email = source_employee["email"].to_s.strip.downcase
      source_name = normalize_name(source_employee["full_name"])
      available_payroll_employees.filter_map do |employee|
        same_email = source_email.present? && employee.email.to_s.strip.downcase == source_email
        same_name = source_name.present? && normalize_name(employee.full_name) == source_name
        next unless same_email || same_name

        {
          "employee_id" => employee.id,
          "employee_name" => employee.full_name,
          "email" => employee.email,
          "basis" => suggestion_basis(same_email:, same_name:)
        }
      end
    end

    def normalize_name(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def suggestion_basis(same_email:, same_name:)
      return "same_email_and_name" if same_email && same_name
      return "same_email" if same_email

      "same_name"
    end
  end
end
