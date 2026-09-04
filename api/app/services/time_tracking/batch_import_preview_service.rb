# frozen_string_literal: true

module TimeTracking
  class BatchImportPreviewService
    VALIDATION_VERSION = "payroll_batch_v2"

    attr_reader :pay_period, :source, :start_date, :end_date

    def initialize(pay_period:, source:, start_date: nil, end_date: nil)
      @pay_period = pay_period
      @source = source
      @start_date = parse_date(start_date.presence || pay_period.start_date, "start_date")
      @end_date = parse_date(end_date.presence || pay_period.end_date, "end_date")
    end

    def call
      validate_request!
      workweek = legal_workweek!
      client = Client.new(source)
      batch_summary = discover_batch!(client)
      raw = client.payroll_batch(batch_id: batch_summary.fetch("id"))
      PayrollBatchPayloadValidator.new(payload: raw, start_date: start_date, end_date: end_date).validate!
      validate_summary_identity!(batch_summary, raw)
      validate_source_workweeks!(raw, workweek)

      processed = process(raw, workweek: workweek)
      warnings = processed.fetch(:rows).flat_map do |row|
        row.fetch(:warnings).map do |warning|
          warning.merge(source_user_id: row.fetch(:source_user_id), display_name: row.fetch(:source_display_name))
        end
      end
      import = persist_preview!(raw, processed, warnings)
      source.update!(last_synced_at: Time.current)
      import
    end

    private

    def validate_request!
      raise ArgumentError, "Finalized batch import is only available for AIRE Services" unless source.source_type == "aire_services"
      raise ArgumentError, "Time tracking source is inactive" unless source.active?
      raise ArgumentError, "Source does not belong to this company" unless source.company_id == pay_period.company_id
      raise ArgumentError, "end_date must be on or after start_date" if end_date < start_date
      unless start_date == pay_period.start_date && end_date == pay_period.end_date
        raise ArgumentError, "AIRE finalized batches must exactly match the selected pay period dates"
      end
    end

    def legal_workweek!
      workweek = pay_period.resolved_company_workweek
      raise ArgumentError, "Confirm the legal overtime workweek before importing time" unless workweek&.confirmed?
      if workweek.starts_at_minutes.to_i != 0
        raise ArgumentError,
              "AIRE payroll batches currently require a legal workweek that starts at midnight; " \
              "timestamp-based boundaries are not supported yet"
      end

      workweek
    end

    def discover_batch!(client)
      response = client.payroll_batches(start_date: start_date.iso8601, end_date: end_date.iso8601)
      matches = response.fetch("payroll_batches").select do |batch|
        batch.is_a?(Hash) && batch["start_date"] == start_date.iso8601 && batch["end_date"] == end_date.iso8601
      end
      raise ArgumentError, "AIRE has not finalized a payroll batch for these exact dates" if matches.empty?
      raise ArgumentError, "AIRE returned more than one finalized payroll batch for these dates" if matches.many?

      matches.first
    end

    def validate_summary_identity!(summary, raw)
      unless summary["id"] == raw["batch_id"] && summary["checksum"] == raw.dig("export", "checksum") &&
             summary["cutoff_at"] == raw["cutoff_at"]
        raise ArgumentError, "AIRE payroll batch list and detail metadata do not match"
      end
    end

    def validate_source_workweeks!(raw, workweek)
      mismatched = Array(raw["employees"]).flat_map { |employee| Array(employee["adjustments"]) }.find do |adjustment|
        Date.iso8601(adjustment.fetch("original_week_start")).wday != workweek.starts_on_weekday
      end
      return unless mismatched

      raise ArgumentError,
            "AIRE's source workweek does not match this company's confirmed legal workweek; " \
            "review the workweek settings before importing"
    end

    def process(raw, workweek:)
      matcher = EmployeeMatcher.new(company: pay_period.company, source: source)
      rows = Array(raw["employees"]).map do |source_employee|
        build_row(source_employee, matcher)
      end
      issues = raw.fetch("issues")

      {
        source: raw.fetch("source"),
        schema_version: raw.fetch("schema_version"),
        validation_version: VALIDATION_VERSION,
        batch_id: raw.fetch("batch_id"),
        batch_checksum: raw.dig("export", "checksum"),
        cutoff_at: raw.fetch("cutoff_at"),
        finalized_at: raw.dig("export", "finalized_at"),
        start_date: start_date.iso8601,
        end_date: end_date.iso8601,
        fetch_start_date: start_date.iso8601,
        fetch_end_date: end_date.iso8601,
        legal_workweek: {
          company_workweek_id: workweek.id,
          starts_on_weekday: workweek.starts_on_weekday,
          starts_at_minutes: workweek.starts_at_minutes,
          timezone: workweek.timezone
        },
        rows: rows,
        exclusions: raw.fetch("exclusions"),
        summary: raw.fetch("summary"),
        issues: issues,
        negative_adjustment_count: issues.fetch("negative_adjustment_count", negative_adjustment_count(raw)).to_i,
        ready: rows.all? { |row| row.fetch(:ready) }
      }
    end

    def build_row(source_employee, matcher)
      match = matcher.match(source_employee)
      categories = category_buckets(source_employee.fetch("adjustments"))
      wage_rate_match = match_wage_rate_buckets(categories, match[:employee_id])
      categories = wage_rate_match.fetch(:categories)
      regular_hours = decimal(source_employee.fetch("regular_hours"))
      overtime_hours = decimal(source_employee.fetch("overtime_hours"))
      total_hours = decimal(source_employee.fetch("total_hours"))
      estimated_gross_delta_cents = payroll_gross_delta_cents(categories)
      warnings = warnings_for(
        source_employee,
        match,
        categories,
        wage_rate_match.fetch(:requires_category_mapping),
        total_hours: total_hours,
        regular_hours: regular_hours,
        overtime_hours: overtime_hours,
        estimated_gross_delta_cents: estimated_gross_delta_cents
      )

      {
        source_user_id: source_employee.fetch("source_user_id").to_s,
        source_user_uuid: source_employee["source_user_uuid"].presence,
        source_email: source_employee["email"],
        source_display_name: source_employee["display_name"].presence || source_employee.fetch("source_user_id").to_s,
        employee_id: match[:employee_id],
        employee_name: match[:employee_name],
        match_method: match[:match_method],
        match_score: match[:match_score],
        regular_hours: number(regular_hours),
        overtime_hours: number(overtime_hours),
        total_hours: number(total_hours),
        estimated_gross_delta: (estimated_gross_delta_cents / 100).round(2).to_f,
        categories: categories,
        source_kind_counts: Array(source_employee["adjustments"]).each_with_object(Hash.new(0)) do |adjustment, counts|
          counts[adjustment.fetch("source_kind")] += 1
        end,
        issues: {},
        warnings: warnings,
        ready: match[:employee_id].present? && warnings.empty?
      }
    end

    def category_buckets(adjustments)
      buckets = {}
      Array(adjustments).each do |adjustment|
        category = adjustment["category"] || {}
        key = category_bucket_key(adjustment)
        bucket = buckets[key] ||= {
          source_category_id: adjustment["source_category_id"].to_s.presence,
          key: category["key"].to_s.presence,
          name: category["name"].presence || "Uncategorized",
          total_hours: 0.to_d,
          regular_hours: 0.to_d,
          overtime_hours: 0.to_d,
          source_kinds: Set.new,
          source_time_entry_ids: Set.new,
          original_work_dates: Set.new
        }
        bucket[:total_hours] += decimal(adjustment.fetch("total_hours"))
        bucket[:regular_hours] += decimal(adjustment.fetch("regular_hours"))
        bucket[:overtime_hours] += decimal(adjustment.fetch("overtime_hours"))
        bucket[:source_kinds] << adjustment.fetch("source_kind")
        bucket[:source_time_entry_ids] << adjustment.fetch("source_time_entry_id")
        bucket[:original_work_dates] << adjustment.fetch("original_work_date")
      end

      buckets.values.map do |bucket|
        bucket.merge(
          total_hours: number(bucket[:total_hours]),
          hours: number(bucket[:total_hours]),
          regular_hours: number(bucket[:regular_hours]),
          overtime_hours: number(bucket[:overtime_hours]),
          source_kinds: bucket[:source_kinds].to_a.sort,
          source_time_entry_ids: bucket[:source_time_entry_ids].to_a.sort,
          original_work_dates: bucket[:original_work_dates].to_a.sort
        )
      end.sort_by do |bucket|
        [ bucket[:name].to_s, bucket[:key].to_s, bucket[:source_category_id].to_s, bucket[:source_kinds].join(",") ]
      end
    end

    def category_bucket_key(adjustment)
      category = adjustment["category"] || {}
      [
        adjustment["source_category_id"],
        category["key"],
        category["name"],
        adjustment["source_kind"]
      ].map(&:to_s).map(&:strip).join("|")
    end

    def match_wage_rate_buckets(categories, employee_id)
      result = { categories: categories, requires_category_mapping: false }
      return result if categories.blank? || employee_id.blank?

      employee = Employee.includes(:employee_wage_rates).find_by(id: employee_id, company_id: pay_period.company_id)
      return result unless employee&.hourly? || employee&.contractor_hourly?

      active_rates = employee.active_wage_rates.to_a
      result[:requires_category_mapping] = categories.any?(&:present?)
      result[:categories] = categories.map do |category|
        rate, method = find_wage_rate(category, active_rates)
        category.merge(
          employee_wage_rate_id: rate&.id,
          wage_rate_label: rate&.label,
          wage_rate_match_method: method,
          payroll_rate_cents: wage_rate_cents(rate)
        )
      end
      result
    end

    def find_wage_rate(category, rates)
      label_matches = rates.select do |rate|
        candidates = [ category[:key], category[:name] ].compact_blank.map { |value| normalize_match_key(value) }
        candidates.include?(normalize_match_key(rate.label))
      end
      return [ label_matches.first, "label" ] if label_matches.one?

      [ nil, nil ]
    end

    def warnings_for(source_employee, match, categories, requires_category_mapping, total_hours:, regular_hours:, overtime_hours:, estimated_gross_delta_cents:)
      warnings = []
      if match[:employee_id].blank? && (total_hours.nonzero? || categories.any?)
        warnings << warning("unmatched_employee", "Map #{source_employee['display_name'].presence || 'this AIRE user'} to a payroll employee before importing")
      end
      if total_hours.negative? || regular_hours.negative? || overtime_hours.negative?
        warnings << warning(
          "negative_net_hours",
          "This batch would make the employee's resulting regular or overtime hours negative. Use the payroll correction workflow instead of an ordinary pay-period import."
        )
      end
      if estimated_gross_delta_cents.negative?
        warnings << warning(
          "negative_net_pay_delta",
          "This batch produces a negative Cornerstone payroll gross adjustment for the employee. Use the payroll correction workflow instead of an ordinary pay-period import."
        )
      end
      if requires_category_mapping
        categories.each do |category|
          next if category[:total_hours].to_d.zero?
          next if category[:employee_wage_rate_id].present?

          warnings << warning(
            "unmapped_wage_rate",
            "Map #{category[:name]} to one of this employee's Cornerstone earning types before importing",
            source_category_id: category[:source_category_id],
            source_category_key: category[:key],
            source_category_name: category[:name]
          )
        end
      end
      warnings
    end

    def persist_preview!(raw, processed, warnings)
      batch_id = raw.fetch("batch_id")
      checksum = raw.dig("export", "checksum")
      attrs = {
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: start_date,
        end_date: end_date,
        fetch_start_date: start_date,
        fetch_end_date: end_date,
        source_payload_hash: checksum,
        external_batch_id: batch_id,
        external_batch_checksum: checksum,
        contract_version: raw.fetch("schema_version"),
        source_cutoff_at: Time.iso8601(raw.fetch("cutoff_at")),
        status: "previewed",
        raw_payload: raw,
        processed_payload: processed,
        warnings: warnings
      }

      TimeTrackingImport.transaction do
        existing = TimeTrackingImport.lock.find_by(time_tracking_source: source, external_batch_id: batch_id)
        return validate_existing_import!(existing, checksum) if existing

        begin
          TimeTrackingImport.transaction(requires_new: true) { TimeTrackingImport.create!(attrs) }
        rescue ActiveRecord::RecordNotUnique
          existing = TimeTrackingImport.lock.find_by!(time_tracking_source: source, external_batch_id: batch_id)
          validate_existing_import!(existing, checksum)
        end
      end
    end

    def validate_existing_import!(import, checksum)
      unless ActiveSupport::SecurityUtils.secure_compare(import.external_batch_checksum, checksum)
        raise ArgumentError, "AIRE returned a different checksum for an existing payroll batch ID"
      end
      if import.pay_period_id != pay_period.id || import.start_date != start_date || import.end_date != end_date
        raise ArgumentError, "This AIRE payroll batch is already linked to a different pay period"
      end

      import
    end

    def negative_adjustment_count(raw)
      Array(raw["employees"]).sum do |employee|
        Array(employee["adjustments"]).count do |adjustment|
          [ adjustment["total_hours"], adjustment["regular_hours"], adjustment["overtime_hours"] ].any? { |value| decimal(value).negative? }
        end
      end
    end

    def payroll_gross_delta_cents(categories)
      Array(categories).sum do |category|
        rate_cents = decimal(category[:payroll_rate_cents] || 0)
        regular = decimal(category[:regular_hours] || 0)
        overtime = decimal(category[:overtime_hours] || 0)
        (regular * rate_cents) + (overtime * rate_cents * BigDecimal("1.5"))
      end
    end

    def parse_date(value, name)
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise ArgumentError, "#{name} must be a valid ISO 8601 date (YYYY-MM-DD)"
    end

    def decimal(value)
      BigDecimal(value.to_s)
    end

    def number(value)
      value.to_d.round(2).to_f
    end

    def wage_rate_cents(rate)
      (BigDecimal(rate.rate.to_s) * 100).round.to_i if rate&.rate.present?
    rescue ArgumentError
      nil
    end

    def normalize_match_key(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def warning(code, message, extra = {})
      { code: code, message: message }.merge(extra)
    end
  end
end
