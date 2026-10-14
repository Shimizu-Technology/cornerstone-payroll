# frozen_string_literal: true

module TimeTracking
  # Allocations are immutable: they retain the mapping selected at import time,
  # independently of editable worksheet JSON and subsequent profile rate edits.
  class SourceEarningsConservation
    MESSAGE = "Imported source hours or captured earning rates changed. Reload the saved import; use the correction workflow to change source work."
    LINE_KEYS = %w[source_time_entry_id line_key source_time_entry_version source_kind original_work_date total_hours regular_hours overtime_hours].freeze

    def self.validate!(item, calculated: false)
      return true unless item.persisted?
      rows = item.time_tracking_entry_allocations.includes(:time_tracking_import).to_a
      return true if rows.empty?

      valid = rows.all? { |row| frozen_line_matches?(row, item) } &&
        rows.sum(&:regular_hours) == item.hours_worked.to_d &&
        rows.sum(&:overtime_hours) == item.overtime_hours.to_d
      raise ArgumentError, MESSAGE unless valid

      captured = rows.select { |row| row.earning_snapshot.present? }
      # Older allocations never recorded the selected wage mapping. Retain their
      # history and enforce exact frozen hours; do not manufacture rate evidence.
      return true if captured.empty?
      raise ArgumentError, MESSAGE unless captured.size == rows.size
      captured.map(&:time_tracking_import).uniq(&:id).each do |import|
        raw = import.raw_payload
        source = import.time_tracking_source
        PayrollBatchPayloadValidator.new(payload: raw, start_date: import.start_date, end_date: import.end_date,
          expected_source: source.connector.source_identifier).validate!
        ConnectionIdentity.validate!(source: source, payload: raw)
        raise ArgumentError, MESSAGE unless raw["batch_id"] == import.external_batch_id &&
          raw.dig("export", "checksum") == import.external_batch_checksum &&
          CanonicalPayload.checksum(raw.except("export")) == import.external_batch_checksum &&
          import.source_payload_hash == import.external_batch_checksum
      end

      expected = captured.group_by { |row| row.earning_snapshot.fetch("source_bucket_key") }
      buckets = item.wage_rate_hours.select { |entry| entry["source_bucket_key"].present? }
      raise ArgumentError, MESSAGE unless buckets.size == expected.size && buckets.map { |entry| entry["source_bucket_key"] }.uniq.size == buckets.size
      expected.each do |key, allocations|
        snapshot = allocations.first.earning_snapshot
        bucket = buckets.find { |entry| entry["source_bucket_key"] == key }
        raise ArgumentError, MESSAGE unless bucket && allocations.all? { |row| row.earning_snapshot == snapshot } &&
          bucket["employee_wage_rate_id"].to_s == snapshot["employee_wage_rate_id"].to_s &&
          bucket["label"] == snapshot["label"] &&
          decimal(bucket["rate"]) == decimal(snapshot["rate"]) && bucket["active"] != false &&
          canonical_lines(bucket["source_lines"]) == canonical_lines(snapshot["source_lines"]) &&
          decimal(bucket["regular_hours"]) == allocations.sum(&:regular_hours) &&
          decimal(bucket["overtime_hours"]) == allocations.sum(&:overtime_hours)
      end
      raise ArgumentError, MESSAGE unless item.wage_rate_hours.sum { |entry| decimal(entry["regular_hours"]) } == rows.sum(&:regular_hours) &&
        item.wage_rate_hours.sum { |entry| decimal(entry["overtime_hours"]) } == rows.sum(&:overtime_hours)

      if calculated
        %w[regular overtime].each do |kind|
          multiplier = kind == "overtime" ? BigDecimal("1.5") : 1.to_d
          expected_amount = buckets.sum { |entry| (decimal(entry["#{kind}_hours"]) * decimal(entry["rate"]) * multiplier).round(2) }
          actual_amount = item.payroll_item_earnings.where(category: kind).sum(:amount)
          raise ArgumentError, MESSAGE unless actual_amount == expected_amount
        end
      end
      true
    rescue KeyError, TypeError, PayrollBatchPayloadValidator::Error, ConnectionIdentity::Error
      raise ArgumentError, MESSAGE
    end

    def self.frozen_line_matches?(row, item)
      import = row.time_tracking_import
      employee = Array(import.raw_payload["employees"]).find { |candidate| candidate["source_user_id"].to_s == row.source_user_id && candidate["source_user_uuid"].presence == row.source_user_uuid }
      line = Array(employee&.dig("adjustments")).find { |candidate| candidate["source_time_entry_id"].to_s == row.source_time_entry_id && candidate["line_key"].to_s == row.line_key }
      return false unless line && row.company_id == item.company_id && row.pay_period_id == item.pay_period_id &&
        row.employee_id == item.employee_id && row.time_tracking_source_id == import.time_tracking_source_id &&
        import.pay_period_id == item.pay_period_id && row.source_kind == line["source_kind"] &&
        row.original_work_date.iso8601 == line["original_work_date"] && row.category_snapshot == (line["category"] || {}) &&
        %w[total_hours regular_hours overtime_hours].all? { |field| row.public_send(field) == decimal(line[field]) }

      return true if row.earning_snapshot.blank?
      refs = Array(row.earning_snapshot["source_lines"]).select { |ref| ref["source_time_entry_id"].to_s == row.source_time_entry_id && ref["line_key"].to_s == row.line_key }
      refs.one? && canonical_lines(refs) == canonical_lines([ line.slice(*LINE_KEYS) ])
    end

    def self.canonical_lines(lines)
      Array(lines).map do |line|
        line.stringify_keys.slice(*LINE_KEYS).tap do |normalized|
          %w[total_hours regular_hours overtime_hours].each { |field| normalized[field] = decimal(normalized[field]).to_s("F") }
        end
      end.sort_by { |line| [ line["source_time_entry_id"].to_s, line["line_key"].to_s ] }
    end

    def self.decimal(value)
      number = BigDecimal(value.to_s, exception: false)
      raise ArgumentError, MESSAGE unless number&.finite?
      number
    end
  end
end
