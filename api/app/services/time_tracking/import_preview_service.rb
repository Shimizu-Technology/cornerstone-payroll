# frozen_string_literal: true

module TimeTracking
  class ImportPreviewService
    attr_reader :pay_period, :source, :start_date, :end_date

    def initialize(pay_period:, source:, start_date: nil, end_date: nil)
      @pay_period = pay_period
      @source = source
      @start_date = parse_date(start_date.presence || pay_period.start_date, "start_date")
      @end_date = parse_date(end_date.presence || pay_period.end_date, "end_date")
    end

    def call
      raise ArgumentError, "Time tracking source is inactive" unless source.active?
      raise ArgumentError, "Source does not belong to this company" unless source.company_id == pay_period.company_id
      raise ArgumentError, "end_date must be on or after start_date" if end_date < start_date

      fetch_start = OvertimeCalculator.fetch_start_for(start_date)
      fetch_end = OvertimeCalculator.fetch_end_for(end_date)
      raw = Client.new(source).time_summary(start_date: fetch_start.iso8601, end_date: fetch_end.iso8601)
      processed = process(raw)
      warnings = processed[:rows].flat_map { |row| row[:warnings].map { |warning| warning.merge(source_user_id: row[:source_user_id], display_name: row[:source_display_name]) } }
      payload_hash = Digest::SHA256.hexdigest(JSON.generate(raw))

      import = save_preview_import!(
        lookup_attrs: {
          pay_period: pay_period,
          time_tracking_source: source,
          start_date: start_date,
          end_date: end_date,
          source_payload_hash: payload_hash
        },
        import_attrs: {
          status: "previewed",
          fetch_start_date: fetch_start,
          fetch_end_date: fetch_end,
          raw_payload: raw,
          processed_payload: processed,
          warnings: warnings
        }
      )
      source.update!(last_synced_at: Time.current)

      import
    end

    private

    def save_preview_import!(lookup_attrs:, import_attrs:)
      import = TimeTrackingImport.find_or_initialize_by(lookup_attrs)
      persist_preview_import!(import, import_attrs)
    rescue ActiveRecord::RecordNotUnique
      import = TimeTrackingImport.find_by!(lookup_attrs)
      persist_preview_import!(import, import_attrs)
    end

    def persist_preview_import!(import, import_attrs)
      if import.persisted?
        import.with_lock { assign_and_save_preview!(import, import_attrs) }
      else
        assign_and_save_preview!(import, import_attrs)
      end

      import
    end

    def assign_and_save_preview!(import, import_attrs)
      raise ArgumentError, "This exact time tracking payload has already been applied" if import.status == "applied"

      import.assign_attributes(import_attrs)
      import.save!
    end

    def parse_date(value, name)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise ArgumentError, "#{name} must be a valid ISO 8601 date (YYYY-MM-DD)"
    end

    def process(raw)
      matcher = EmployeeMatcher.new(company: pay_period.company, source: source)
      overtime = OvertimeCalculator.new(period_start: start_date, period_end: end_date)
      rows = Array(raw["employees"]).filter_map do |source_employee|
        match = matcher.match(source_employee)
        split = overtime.split_days(source_employee["days"])
        issues = source_employee["issues"] || {}
        warnings = warnings_for(source_employee, issues, match, split)

        next if split[:total_hours].to_f <= 0 && warnings.empty?

        {
          source_user_id: source_employee["source_user_id"].to_s,
          source_email: source_employee["email"],
          source_display_name: source_employee["display_name"],
          employee_id: match[:employee_id],
          employee_name: match[:employee_name],
          match_method: match[:match_method],
          match_score: match[:match_score],
          regular_hours: split[:regular_hours],
          overtime_hours: split[:overtime_hours],
          total_hours: split[:total_hours],
          days: split[:days],
          issues: issues,
          warnings: warnings,
          ready: match[:employee_id].present? && warnings.empty?
        }
      end

      {
        source: raw["source"],
        start_date: start_date.iso8601,
        end_date: end_date.iso8601,
        fetch_start_date: OvertimeCalculator.fetch_start_for(start_date).iso8601,
        fetch_end_date: OvertimeCalculator.fetch_end_for(end_date).iso8601,
        rows: rows,
        ready: rows.all? { |row| row[:ready] }
      }
    end

    def warnings_for(source_employee, issues, match, split)
      warnings = []
      warnings << warning("unmatched_employee", "Map #{source_employee['display_name'].presence || 'this source user'} to a payroll employee before importing") if match[:employee_id].blank? && split[:total_hours].to_f.positive?
      warnings << warning("pending_entries", "#{issues['pending_count']} pending time entries need review") if issues["pending_count"].to_i.positive?
      warnings << warning("pending_overtime", "#{issues['pending_overtime_count']} entries have pending overtime review") if issues["pending_overtime_count"].to_i.positive?
      warnings << warning("denied_entries", "#{issues['denied_count']} denied time entries need correction") if issues["denied_count"].to_i.positive?
      warnings << warning("denied_overtime", "#{issues['denied_overtime_count']} entries have denied overtime review") if issues["denied_overtime_count"].to_i.positive?
      warnings << warning("open_clock", "#{issues['open_clock_count']} open clock-in(s) in the fetched work weeks") if issues["open_clock_count"].to_i.positive?
      warnings
    end

    def warning(code, message)
      { code: code, message: message }
    end
  end
end
