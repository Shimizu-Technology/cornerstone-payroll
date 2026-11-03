# frozen_string_literal: true

module TimeTracking
  class AireCategorySetup
    def self.call!(source:, actor:, reason:, evidence:)
      raise ArgumentError, "This reviewed activation setup is only for company 2's AIRE source" unless source.company_id == 2 && source.source_type == "aire_services"
      raise ArgumentError, "Payroll operations access required" unless HistoryApproval.allowed?(actor, source.company)
      company = source.company
      find_person = ->(name) do
        matches = company.employees.select { |employee| TimeTrackingCategoryMapping.normalized(employee.full_name) == name }
        raise ArgumentError, "Confirm the unique #{name} employee before setup" unless matches.one?
        matches.sole
      end
      anthony = find_person.call("anthony ezra")
      isiah = find_person.call("isiah gonzales")
      pilots = company.employees.includes(:employee_wage_rates).select do |employee|
        employee.employee_wage_rates.any? { |rate| TimeTrackingCategoryMapping.normalized(rate.label) == "flight hours" }
      end
      definitions = [
        [ "solo", "Flight Hours", true, pilots.map(&:id) ],
        [ "maintenance", "Maintenance", true, [ anthony.id ] ],
        [ "other", nil, false, [ isiah.id ] ],
        [ "uncategorized", nil, false, ([ anthony.id, isiah.id ] + pilots.map(&:id)).uniq ]
      ]
      source.with_lock do
        raise ArgumentError, "Category activation setup requires an unpublished connection without a history approval" if source.aire_payroll_calendar_periods.exists? || source.aire_verified_history_rollout_receipts.exists?
        definitions.each do |key, label, importing, scope|
          row = TimeTrackingCategoryMapping.find_or_initialize_by(time_tracking_source: source, source_category_key: key)
          before = row.attributes
          row.assign_attributes(company: company, earning_label: label, fallback_earning_label: key == "maintenance" ? "Regular" : nil, import_enabled: importing,
            historical_attribution: true, historical_employee_ids: scope.sort, historical_run_limits: key == "uncategorized" ? { isiah.id.to_s => [ 61 ] } : {},
            history_through_on: source.cutoff_enforcement_starts_on - 1.day,
            reviewed_by: actor, reason: reason, evidence: evidence)
          next unless row.changed?
          row.save!
          AuditLog.record!(user: actor, company_id: company.id, action: "time_tracking_category_mapping#reviewed",
            record_type: "TimeTrackingCategoryMapping", record_id: row.id, event_category: "payroll",
            metadata: { before: before, after: row.attributes })
        end
      end
      { solo: "Solo → each employee's active Flight Hours rate; missing/ambiguous rates block",
        maintenance: "Aircraft Maintenance → each employee’s active Maintenance rate, otherwise Regular; missing both blocks",
        history_through_on: source.cutoff_enforcement_starts_on - 1.day }
    end
  end
end
