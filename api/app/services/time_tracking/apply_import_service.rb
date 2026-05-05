# frozen_string_literal: true

module TimeTracking
  class ApplyImportService
    def initialize(import:, mappings:, applied_by:)
      @import = import
      @mappings = Array(mappings)
      @applied_by = applied_by
      @pay_period = import.pay_period
      @company = @pay_period.company
      @source = import.time_tracking_source
    end

    def call
      raise ArgumentError, "Cannot apply to a non-editable pay period" unless @pay_period.can_edit?

      rows = Array(@import.processed_payload["rows"] || @import.processed_payload[:rows])
      mapping_by_source_id = @mappings.index_by { |m| (m[:source_user_id] || m["source_user_id"]).to_s }
      results = { applied: [], skipped: [], errors: [] }
      seen_employee_ids = Set.new
      current_import_source = import_source_key

      @import.with_lock do
        raise ArgumentError, "Only previewed time tracking imports can be applied" unless @import.status == "previewed"

        rows.each do |row|
          source_user_id = row["source_user_id"].to_s
          override = mapping_by_source_id[source_user_id] || {}
          include_value = override.key?(:include) || override.key?("include") ? (override[:include] || override["include"]) : true
          include_row = ActiveModel::Type::Boolean.new.cast(include_value)
          unless include_row
            results[:skipped] << { source_user_id: source_user_id, reason: "excluded" }
            next
          end

          employee_id = (override[:employee_id] || override["employee_id"] || row["employee_id"]).presence
          if employee_id.blank?
            results[:errors] << { source_user_id: source_user_id, error: "Employee mapping required" }
            next
          end

          blocking_warnings = Array(row["warnings"]).reject do |warning|
            warning_code = warning.respond_to?(:[]) ? warning["code"] || warning[:code] : nil
            warning_code == "unmatched_employee" && employee_id.present?
          end
          if blocking_warnings.any?
            results[:errors] << { source_user_id: source_user_id, error: "Resolve time tracking warnings before importing" }
            next
          end

          employee = Employee.active.find_by(id: employee_id, company_id: @company.id)
          unless employee
            results[:errors] << { source_user_id: source_user_id, employee_id: employee_id, error: "Employee not found or inactive" }
            next
          end

          if seen_employee_ids.include?(employee.id)
            results[:errors] << { source_user_id: source_user_id, employee_id: employee.id, error: "Duplicate payroll employee mapping" }
            next
          end
          seen_employee_ids.add(employee.id)

          persist_mapping!(row, employee)
          item = @pay_period.payroll_items.lock.find_or_initialize_by(employee_id: employee.id)
          if item.persisted? && item.import_source.to_s.start_with?("time_tracking:")
            results[:errors] << { source_user_id: source_user_id, employee_id: employee.id, error: "Employee already has imported time tracking hours in this pay period" }
            next
          end

          if item.new_record?
            item.company_id = @company.id
            item.employment_type = employee.employment_type
            item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
            item.custom_earnings = employee.default_custom_earnings
          end
          preserved_holiday_hours = item.holiday_hours.to_f
          preserved_pto_hours = item.pto_hours.to_f

          item.clear_wage_rate_hours!
          item.hours_worked = row["regular_hours"].to_f
          item.overtime_hours = row["overtime_hours"].to_f
          item.holiday_hours = preserved_holiday_hours
          item.pto_hours = preserved_pto_hours
          item.import_source = current_import_source
          item.save!

          results[:applied] << {
            employee_id: employee.id,
            employee_name: employee.full_name,
            regular_hours: item.hours_worked.to_f,
            overtime_hours: item.overtime_hours.to_f
          }
        end

        if results[:errors].any?
          raise ActiveRecord::Rollback
        end

        @import.update!(status: "applied", applied_at: Time.current, applied_by: @applied_by)
      end

      results
    end

    private

    def import_source_key
      "time_tracking:#{@source.source_type}:#{@source.id}"
    end

    def persist_mapping!(row, employee)
      lookup_attrs = {
        company: @company,
        time_tracking_source: @source,
        source_user_id: row["source_user_id"].to_s
      }
      mapping = find_or_create_mapping!(lookup_attrs, employee)
      mapping.update!(
        employee: employee,
        source_email: row["source_email"],
        source_display_name: row["source_display_name"]
      )
    end

    def find_or_create_mapping!(lookup_attrs, employee)
      TimeTrackingEmployeeMapping.find_by(lookup_attrs) || create_mapping!(lookup_attrs, employee)
    rescue ActiveRecord::RecordNotUnique
      TimeTrackingEmployeeMapping.find_by!(lookup_attrs)
    end

    def create_mapping!(lookup_attrs, employee)
      TimeTrackingEmployeeMapping.transaction(requires_new: true) do
        TimeTrackingEmployeeMapping.create!(lookup_attrs.merge(employee: employee))
      end
    end
  end
end
