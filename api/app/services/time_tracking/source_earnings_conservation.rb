# frozen_string_literal: true

module TimeTracking
  # Allocations are immutable: they retain the mapping selected at import time,
  # independently of editable worksheet JSON and subsequent profile rate edits.
  class SourceEarningsConservation
    MESSAGE = "Imported source hours or captured earning rates changed. Reload the saved import; use the correction workflow to change source work."
    PAY_BASIS_MESSAGE = "This imported payroll retains its captured pay basis. The employee's pay basis changed; review the saved source import before recalculating. Captured source earnings cannot be replaced with current salary or fee pay."
    LINE_KEYS = %w[source_time_entry_id line_key source_time_entry_version source_kind original_work_date total_hours regular_hours overtime_hours].freeze

    # Presentation shares the financial basis check, without validating remote
    # provenance or changing already accepted historical payroll.
    def self.hold_reason(item)
      return nil unless item.persisted? && item.import_source.to_s.start_with?("time_tracking:")
      return nil if item.pay_period.committed?

      captured = item.time_tracking_entry_allocations.select { |row| row.earning_snapshot.present? }
      return nil if captured.empty?
      if captured.any? { |row| row.earning_snapshot["employment_type"].blank? ||
        (row.earning_snapshot["employment_type"] == "contractor" && row.earning_snapshot["contractor_pay_type"].blank?) }
        return { reason: "This imported payroll's original pay basis is unavailable. Review retained source earnings and original pay setup before recalculating; current setup cannot establish captured pay basis." }
      end
      pay_basis_changed?(item, captured) ? { reason: PAY_BASIS_MESSAGE } : nil
    end

    def self.pay_basis_changed?(item, captured)
      current = Employee.where(id: item.employee_id, company_id: item.company_id).pick(:employment_type, :contractor_pay_type)
      return true unless current

      captured.any? do |row|
        basis = row.earning_snapshot["employment_type"] || item.employment_type_in_database
        basis != item.employment_type || basis != current.first ||
          (basis == "contractor" && row.earning_snapshot["contractor_pay_type"].present? &&
            row.earning_snapshot["contractor_pay_type"] != current.last)
      end
    end

    def self.validate!(item, calculated: false)
      rows = item.persisted? ? item.time_tracking_entry_allocations.includes(:time_tracking_import).to_a : []
      if rows.empty? && item.pay_period&.run_purpose == "adjustment" &&
          TimeTrackingLateHoursRun.where(adjustment_pay_period_id: item.pay_period_id).where.not(applied_at: nil).exists?
        raise ArgumentError, "This late-hours adjustment contains only its selected source hours. Create a separate run for other pay."
      end
      if rows.empty?
        PayrollEarningsRounding.validate!(item) if calculated
        return true
      end

      valid = rows.all? { |row| frozen_line_matches?(row, item) } &&
        rows.sum(&:regular_hours) == item.hours_worked.to_d &&
        rows.sum(&:overtime_hours) == item.overtime_hours.to_d
      raise ArgumentError, MESSAGE unless valid

      captured = rows.select { |row| row.earning_snapshot.present? }
      # Older allocations never recorded the selected wage mapping. Retain their
      # history and enforce exact frozen hours; do not manufacture rate evidence.
      if captured.empty?
        PayrollEarningsRounding.validate!(item) if calculated
        return true
      end
      raise ArgumentError, MESSAGE unless captured.size == rows.size
      raise ArgumentError, PAY_BASIS_MESSAGE if pay_basis_changed?(item, captured)
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
        expected_earnings = buckets.flat_map do |entry|
          %w[regular overtime].filter_map do |kind|
            hours = decimal(entry["#{kind}_hours"])
            rate = decimal(entry["rate"]) * (kind == "overtime" ? BigDecimal("1.5") : 1.to_d)
            amount = hours * rate
            next if amount.zero?
            label = kind == "overtime" ? "#{entry['label']} OT" : entry["label"]
            if amount.positive?
              [ kind, label, hours, rate, PayrollEarningsRounding.line_amount(amount) ]
            else
              [ "other", "#{label} correction reversal", nil, nil, PayrollEarningsRounding.line_amount(amount) ]
            end
          end
        end
        reversal_labels = expected_earnings.select { |entry| entry.first == "other" }.map { |entry| entry[1] }
        actual_earnings = item.payroll_item_earnings.reload.select do |earning|
          earning.category.in?(%w[regular overtime]) || (earning.category == "other" && reversal_labels.include?(earning.label))
        end.map { |earning| [ earning.category, earning.label, earning.hours, earning.rate, earning.amount ] }
        raise ArgumentError, MESSAGE unless canonical_earnings(actual_earnings) == canonical_earnings(expected_earnings)
      end
      PayrollEarningsRounding.validate!(item) if calculated
      true
    rescue KeyError, TypeError, PayrollBatchPayloadValidator::Error, ConnectionIdentity::Error
      raise ArgumentError, MESSAGE
    end

    def self.canonical_earnings(entries)
      normalized_decimal = ->(value) { decimal(value).zero? ? "0.0" : decimal(value).to_s("F") }
      entries.map do |category, label, hours, rate, amount|
        [ category, label, hours && normalized_decimal.call(hours), rate && normalized_decimal.call(rate), normalized_decimal.call(amount) ]
      end.sort_by(&:to_json)
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
