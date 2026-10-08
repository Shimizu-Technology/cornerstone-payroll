# frozen_string_literal: true

module TimeTracking
  class CorrectionCoverage
    def initialize(import)
      @import = import
    end

    def dispositions
      @dispositions ||= TimeTrackingCorrectionDisposition.where(time_tracking_import: @import).map(&:verified!)
    end

    def ordinary_employees
      covered = dispositions.map { |row| identity(row) }.to_set
      Array(@import.raw_payload["employees"]).filter_map do |employee|
        projected = employee.deep_dup
        projected["adjustments"] = Array(projected["adjustments"]).reject do |line|
          covered.include?([ employee["source_user_id"].to_s, line["source_time_entry_id"].to_s, line["line_key"].to_s ])
        end
        next if projected["adjustments"].empty?
        %w[total_hours regular_hours overtime_hours].each do |key|
          projected[key] = projected["adjustments"].sum { |line| line[key].to_d }.to_f
        end
        projected
      end
    end

    def processed_payload
      return @import.processed_payload if dispositions.empty?
      raw = @import.raw_payload.deep_dup
      raw["employees"] = ordinary_employees
      raw["issues"]["negative_adjustment_count"] = raw["employees"].sum do |employee|
        employee["adjustments"].count { |line| line["regular_hours"].to_d.negative? || line["overtime_hours"].to_d.negative? }
      end
      builder = BatchImportPreviewService.new(pay_period: @import.pay_period, source: @import.time_tracking_source)
      builder.send(:process, raw, workweek: @import.pay_period.resolved_company_workweek).deep_stringify_keys
    end

    def verify_complete!
      raw_lines = Array(@import.raw_payload["employees"]).flat_map do |employee|
        employee["adjustments"].map { |line| [ employee["source_user_id"].to_s, line["source_time_entry_id"].to_s, line["line_key"].to_s ] }
      end
      frozen_by_identity = Array(@import.raw_payload["employees"]).each_with_object({}) do |employee, result|
        employee["adjustments"].each do |line|
          result[[ employee["source_user_id"].to_s, line["source_time_entry_id"].to_s, line["line_key"].to_s ]] = [ employee, line ]
        end
      end
      allocations = @import.time_tracking_entry_allocations.reload.to_a
      ordinary = allocations.map { |row| identity(row) }
      covered = dispositions.map { |row| identity(row) }
      unless (ordinary & covered).empty? && (ordinary + covered).sort == raw_lines.sort &&
        allocations.all? { |row|
          employee, line = frozen_by_identity[identity(row)]
          row.pay_period_id == @import.pay_period_id && row.payroll_item.pay_period_id == @import.pay_period_id &&
            row.company_id == @import.pay_period.company_id && row.time_tracking_source_id == @import.time_tracking_source_id &&
            employee && line && row.source_user_uuid == employee["source_user_uuid"].presence &&
            row.source_kind == line["source_kind"] && row.original_work_date.iso8601 == line["original_work_date"] &&
            row.category_snapshot == (line["category"] || {}) &&
            %w[total_hours regular_hours overtime_hours].all? { |key| row.public_send(key) == line[key].to_d }
        }
        raise ArgumentError, "Every frozen line must have exactly one ordinary allocation or verified accounting correction"
      end
      true
    end

    def presentation
      dispositions.map do |row|
        { id: row.id, source_user_id: row.source_user_id, source_time_entry_id: row.source_time_entry_id,
          line_key: row.line_key, total_hours: row.total_hours.to_f, regular_hours: row.regular_hours.to_f,
          overtime_hours: row.overtime_hours.to_f, original_pay_period_id: row.original_allocation.pay_period_id,
          original_payroll_item_id: row.original_allocation.payroll_item_id,
          corrective_pay_period_id: row.corrective_payroll_item.pay_period_id,
          corrective_payroll_item_id: row.corrective_payroll_item_id, accounting_only: true }
      end
    end

    private

    def identity(row)
      [ row.source_user_id.to_s, row.source_time_entry_id.to_s, row.line_key.to_s ]
    end
  end
end
