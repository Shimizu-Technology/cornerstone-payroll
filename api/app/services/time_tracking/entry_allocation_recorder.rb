# frozen_string_literal: true

module TimeTracking
  class EntryAllocationRecorder
    def initialize(time_tracking_import:, payroll_item:, source_employee:)
      @import = time_tracking_import
      @payroll_item = payroll_item
      @source_employee = source_employee
    end

    def call
      Array(source_employee.fetch("adjustments")).each do |adjustment|
        TimeTrackingEntryAllocation.create!(
          company: payroll_item.company,
          time_tracking_source: import.time_tracking_source,
          time_tracking_import: import,
          pay_period: payroll_item.pay_period,
          payroll_item: payroll_item,
          employee: payroll_item.employee,
          source_user_id: source_employee.fetch("source_user_id").to_s,
          source_user_uuid: source_employee["source_user_uuid"].presence,
          source_time_entry_id: adjustment.fetch("source_time_entry_id").to_s,
          line_key: adjustment.fetch("line_key").to_s,
          source_kind: adjustment.fetch("source_kind"),
          original_work_date: Date.iso8601(adjustment.fetch("original_work_date")),
          category_snapshot: adjustment["category"] || {},
          earning_snapshot: earning_snapshot(adjustment),
          total_hours: decimal(adjustment.fetch("total_hours")),
          regular_hours: decimal(adjustment.fetch("regular_hours")),
          overtime_hours: decimal(adjustment.fetch("overtime_hours"))
        )
      end
    end

    private

    attr_reader :import, :payroll_item, :source_employee

    def earning_snapshot(adjustment)
      bucket = payroll_item.wage_rate_hours.find do |entry|
        Array(entry["source_lines"]).any? do |line|
          line["source_time_entry_id"].to_s == adjustment["source_time_entry_id"].to_s &&
            line["line_key"].to_s == adjustment["line_key"].to_s
        end
      end
      return {} unless bucket

      bucket.slice("source_bucket_key", "employee_wage_rate_id", "rate", "label", "source_lines").merge(
        "employment_type" => payroll_item.employment_type,
        "contractor_pay_type" => payroll_item.employee.contractor_pay_type
      )
    end

    def decimal(value)
      BigDecimal(value.to_s).round(2)
    rescue ArgumentError
      raise ArgumentError, "AIRE entry allocation contains invalid hours"
    end
  end
end
