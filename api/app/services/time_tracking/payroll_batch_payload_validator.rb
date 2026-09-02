# frozen_string_literal: true

require "set"
require "time"

module TimeTracking
  class PayrollBatchPayloadValidator
    CONTRACT_VERSION = "2.0"
    SOURCE = "aire_services"
    HOUR_TOLERANCE = 0.01
    SOURCE_KINDS = %w[current carryover correction].freeze

    class Error < StandardError; end

    attr_reader :payload, :start_date, :end_date

    def initialize(payload:, start_date:, end_date:)
      @payload = payload
      @start_date = parse_expected_date(start_date, "start_date")
      @end_date = parse_expected_date(end_date, "end_date")
    end

    def validate!
      raise Error, "Payroll batch payload must be an object" unless payload.is_a?(Hash)

      validate_header!
      validate_checksum!
      employees = array!(payload["employees"], "employees")
      exclusions = array!(payload["exclusions"], "exclusions")
      validate_employees!(employees)
      validate_exclusions!(exclusions)
      validate_summary!(employees, exclusions)
      validate_issues!(employees, exclusions)

      payload
    end

    private

    def validate_header!
      raise Error, "Unsupported payroll batch source" unless payload["source"] == SOURCE
      raise Error, "Unsupported payroll batch schema version" unless payload["schema_version"] == CONTRACT_VERSION
      raise Error, "Payroll batch ID is required" if payload["batch_id"].blank?
      raise Error, "Payroll batch start date does not match the requested period" unless iso_date!(payload["start_date"], "start_date") == start_date
      raise Error, "Payroll batch end date does not match the requested period" unless iso_date!(payload["end_date"], "end_date") == end_date
      cutoff_at = iso_time!(payload["cutoff_at"], "cutoff_at")
      generated_at = iso_time!(payload["generated_at"], "generated_at")
      raise Error, "generated_at must match cutoff_at" unless generated_at == cutoff_at

      export = payload["export"]
      raise Error, "Payroll batch export metadata is required" unless export.is_a?(Hash)
      raise Error, "Payroll batch is not finalized" unless export["readiness_status"] == "finalized"
      raise Error, "Payroll batch export ID does not match" unless export["id"] == payload["batch_id"] && export["batch_id"] == payload["batch_id"]
      raise Error, "Unsupported payroll batch checksum algorithm" unless export["checksum_algorithm"] == "SHA-256"
      raise Error, "Unsupported payroll batch checksum scope" unless export["checksum_scope"] == "payload_without_export"
      raise Error, "Payroll batch checksum is invalid" unless export["checksum"].to_s.match?(/\A[0-9a-f]{64}\z/)
      export_cutoff_at = iso_time!(export["cutoff_at"], "export.cutoff_at")
      finalized_at = iso_time!(export["finalized_at"], "export.finalized_at")
      raise Error, "Payroll batch cutoff metadata does not match" unless export["cutoff_at"] == payload["cutoff_at"]
      raise Error, "Payroll batch finalized_at cannot precede cutoff_at" if finalized_at < export_cutoff_at
    end

    def validate_checksum!
      checksum_payload = payload.deep_dup
      expected = checksum_payload.delete("export").fetch("checksum")
      actual = CanonicalPayload.checksum(checksum_payload)
      raise Error, "Payroll batch checksum verification failed" unless ActiveSupport::SecurityUtils.secure_compare(actual, expected)
    end

    def validate_employees!(employees)
      seen_users = Set.new
      seen_lines = Set.new

      employees.each_with_index do |employee, employee_index|
        path = "employees[#{employee_index}]"
        object!(employee, path)
        source_user_id = required_string!(employee["source_user_id"], "#{path}.source_user_id")
        raise Error, "Duplicate source employee #{source_user_id}" unless seen_users.add?(source_user_id)

        adjustments = array!(employee["adjustments"], "#{path}.adjustments")
        adjustment_totals = adjustments.each_with_index.map do |adjustment, adjustment_index|
          validate_adjustment!(adjustment, "#{path}.adjustments[#{adjustment_index}]", source_user_id, seen_lines)
        end
        assert_hours!(employee, adjustment_totals, path)
      end
    end

    def validate_adjustment!(adjustment, path, source_user_id, seen_lines)
      object!(adjustment, path)
      source_entry_id = required_string!(adjustment["source_time_entry_id"], "#{path}.source_time_entry_id")
      line_key = required_string!(adjustment["line_key"], "#{path}.line_key")
      line_identity = [ source_user_id, source_entry_id, line_key ]
      raise Error, "Duplicate payroll adjustment line #{line_identity.join(':')}" unless seen_lines.add?(line_identity)

      source_kind = adjustment["source_kind"].to_s
      raise Error, "#{path}.source_kind is invalid" unless source_kind.in?(SOURCE_KINDS)
      work_date = iso_date!(adjustment["original_work_date"], "#{path}.original_work_date")
      week_start = iso_date!(adjustment["original_week_start"], "#{path}.original_week_start")
      raise Error, "#{path}.original_work_date cannot be after the batch end date" if work_date > end_date
      if source_kind == "current" && !work_date.between?(start_date, end_date)
        raise Error, "#{path}.current work must fall inside the nominal batch dates"
      end
      unless work_date.between?(week_start, week_start + 6.days)
        raise Error, "#{path}.original_work_date falls outside its source workweek"
      end

      total = finite_number!(adjustment["total_hours"], "#{path}.total_hours")
      regular = finite_number!(adjustment["regular_hours"], "#{path}.regular_hours")
      overtime = finite_number!(adjustment["overtime_hours"], "#{path}.overtime_hours")
      raise Error, "#{path} hours do not reconcile" unless close?(total, regular + overtime)
      if [ total, regular, overtime ].any?(&:negative?) && source_kind != "correction"
        raise Error, "#{path} has negative hours but is not a correction"
      end

      if [ total, regular, overtime ].any?(&:nonzero?)
        category = adjustment["category"]
        object!(category, "#{path}.category")
        category_identity = [ adjustment["source_category_id"], category["key"], category["name"] ].compact_blank
        raise Error, "#{path}.category needs a stable identity" if category_identity.empty?
        if adjustment["source_category_id"].present? && category["id"].present? &&
           adjustment["source_category_id"].to_s != category["id"].to_s
          raise Error, "#{path}.category ID does not match source_category_id"
        end
      end

      { total: total, regular: regular, overtime: overtime }
    end

    def validate_exclusions!(exclusions)
      seen = Set.new
      exclusions.each_with_index do |exclusion, index|
        path = "exclusions[#{index}]"
        object!(exclusion, path)
        source_entry_id = required_string!(exclusion["source_time_entry_id"], "#{path}.source_time_entry_id")
        source_user_id = required_string!(exclusion["source_user_id"], "#{path}.source_user_id")
        reason = required_string!(exclusion["reason"], "#{path}.reason")
        raise Error, "Duplicate payroll exclusion" unless seen.add?([ source_entry_id, source_user_id, reason ])

        iso_date!(exclusion["original_work_date"], "#{path}.original_work_date")
        %w[held_total_hours held_regular_hours held_overtime_hours].each do |field|
          value = finite_number!(exclusion[field], "#{path}.#{field}")
          raise Error, "#{path}.#{field} cannot be negative" if value.negative?
        end
        unless close?(exclusion["held_total_hours"], exclusion["held_regular_hours"].to_d + exclusion["held_overtime_hours"].to_d)
          raise Error, "#{path} held hours do not reconcile"
        end
      end
    end

    def validate_summary!(employees, exclusions)
      summary = payload["summary"]
      object!(summary, "summary")
      adjustments = employees.flat_map { |employee| employee["adjustments"] }
      expected = {
        "employee_count" => employees.size,
        "adjustment_count" => adjustments.size,
        "exclusion_count" => exclusions.size,
        "total_hours" => adjustments.sum { |row| row["total_hours"].to_d },
        "regular_hours" => adjustments.sum { |row| row["regular_hours"].to_d },
        "overtime_hours" => adjustments.sum { |row| row["overtime_hours"].to_d },
        "current_count" => adjustments.count { |row| row["source_kind"] == "current" },
        "carryover_count" => adjustments.count { |row| row["source_kind"] == "carryover" },
        "correction_count" => adjustments.count { |row| row["source_kind"] == "correction" }
      }

      expected.each do |field, value|
        actual = finite_number!(summary[field], "summary.#{field}")
        raise Error, "summary.#{field} does not reconcile" unless close?(actual, value)
      end
    end

    def validate_issues!(employees, exclusions)
      issues = payload["issues"]
      object!(issues, "issues")
      adjustments = employees.flat_map { |employee| employee["adjustments"] }
      expected = {
        "negative_adjustment_count" => adjustments.count do |row|
          row["regular_hours"].to_d.negative? || row["overtime_hours"].to_d.negative?
        end,
        "pending_approval_count" => exclusions.count { |row| row["reason"].in?(%w[pending_approval approved_after_cutoff created_after_cutoff]) },
        "denied_approval_count" => exclusions.count { |row| row["reason"] == "denied_approval" },
        "open_clock_count" => exclusions.count { |row| row["reason"] == "open_clock" },
        "pending_overtime_count" => exclusions.count { |row| row["reason"].in?(%w[pending_overtime overtime_approved_after_cutoff]) },
        "denied_overtime_count" => exclusions.count { |row| row["reason"] == "denied_overtime" }
      }
      expected.each do |field, value|
        actual = finite_number!(issues[field], "issues.#{field}")
        raise Error, "issues.#{field} does not reconcile" unless close?(actual, value)
      end
      missing_category_count = finite_number!(issues["missing_category_count"], "issues.missing_category_count")
      raise Error, "issues.missing_category_count must be zero for a finalized batch" unless missing_category_count.zero?
    end

    def assert_hours!(employee, rows, path)
      expected = {
        "total_hours" => rows.sum { |row| row[:total] },
        "regular_hours" => rows.sum { |row| row[:regular] },
        "overtime_hours" => rows.sum { |row| row[:overtime] }
      }
      expected.each do |field, value|
        actual = finite_number!(employee[field], "#{path}.#{field}")
        raise Error, "#{path}.#{field} does not reconcile" unless close?(actual, value)
      end
    end

    def object!(value, path)
      raise Error, "#{path} must be an object" unless value.is_a?(Hash)
    end

    def array!(value, path)
      raise Error, "#{path} must be an array" unless value.is_a?(Array)

      value
    end

    def required_string!(value, path)
      result = value.to_s.strip
      raise Error, "#{path} is required" if result.blank?

      result
    end

    def finite_number!(value, path)
      number = BigDecimal(value.to_s)
      raise ArgumentError unless number.finite?

      number
    rescue ArgumentError, TypeError
      raise Error, "#{path} must be a finite number"
    end

    def close?(left, right)
      (left.to_d - right.to_d).abs <= HOUR_TOLERANCE
    end

    def parse_expected_date(value, path)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise Error, "#{path} must be a valid ISO date"
    end

    def iso_date!(value, path)
      Date.iso8601(value.to_s)
    rescue Date::Error
      raise Error, "#{path} must be a valid ISO date"
    end

    def iso_time!(value, path)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      raise Error, "#{path} must be a valid ISO timestamp"
    end
  end
end
