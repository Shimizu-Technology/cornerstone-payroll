# frozen_string_literal: true

module TimeTracking
  class ApplyImportService
    def initialize(import:, mappings:, applied_by:, acknowledge_negative_adjustments: false, negative_adjustment_note: nil)
      @import = import
      @mappings = Array(mappings)
      @applied_by = applied_by
      @pay_period = import.pay_period
      @company = @pay_period.company
      @source = import.time_tracking_source
      @acknowledge_negative_adjustments = ActiveModel::Type::Boolean.new.cast(acknowledge_negative_adjustments)
      @negative_adjustment_note = negative_adjustment_note.to_s.strip
    end

    def call
      acknowledgement_ids = []
      results = @pay_period.with_lock { apply_locked!(acknowledgement_ids) }
      AirePayrollAcknowledgement.dispatch_pending!(ids: acknowledgement_ids)
      results
    end

    private

    def apply_locked!(acknowledgement_ids)
      raise ArgumentError, "Cannot apply to a non-editable pay period" unless @pay_period.can_edit?
      results = nil

      @import.with_lock(requires_new: true) do
        raise ArgumentError, "Only previewed time tracking imports can be applied" unless @import.status == "previewed"
        validate_preview_provenance!
        validate_negative_adjustment_acknowledgement!

        rows = Array(@import.processed_payload["rows"] || @import.processed_payload[:rows])
        mapping_by_source_id = @mappings.index_by { |m| (m[:source_user_id] || m["source_user_id"]).to_s }
        employee_ids = rows.filter_map do |row|
          source_user_id = row["source_user_id"].to_s
          override = mapping_by_source_id[source_user_id] || {}
          (override[:employee_id] || override["employee_id"] || row["employee_id"]).presence&.to_i
        end.uniq
        results = { applied: [], skipped: [], errors: [] }
        seen_employee_ids = Set.new
        current_import_source = import_source_key
        excluded_employee_ids = @pay_period.pay_period_excluded_employees.pluck(:employee_id).to_set

        employees_by_id = Employee.active.includes(:employee_wage_rates).where(id: employee_ids, company_id: @company.id).index_by(&:id)

        rows.each do |row|
          source_user_id = row["source_user_id"].to_s
          override = mapping_by_source_id[source_user_id] || {}
          include_value = override.key?(:include) || override.key?("include") ? (override[:include] || override["include"]) : true
          include_row = ActiveModel::Type::Boolean.new.cast(include_value)
          if finalized_batch? && !include_row
            results[:errors] << { source_user_id: source_user_id, error: "Finalized AIRE batch rows cannot be skipped" }
            next
          end
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
            resolved_warning?(warning, employee_id)
          end
          if blocking_warnings.any?
            correction_warning = blocking_warnings.find do |warning|
              (warning["code"] || warning[:code]).in?(%w[negative_net_hours negative_net_pay_delta])
            end
            error = correction_warning ? (correction_warning["message"] || correction_warning[:message]) : "Resolve time tracking warnings before importing"
            results[:errors] << { source_user_id: source_user_id, error: error }
            next
          end

          employee = employees_by_id[employee_id.to_i]
          unless employee
            results[:errors] << { source_user_id: source_user_id, employee_id: employee_id, error: "Employee not found or inactive" }
            next
          end
          if excluded_employee_ids.include?(employee.id)
            results[:skipped] << { source_user_id: source_user_id, employee_id: employee.id, reason: "Excluded from this pay period" }
            next
          end

          if seen_employee_ids.include?(employee.id)
            results[:errors] << { source_user_id: source_user_id, employee_id: employee.id, error: "Duplicate payroll employee mapping" }
            next
          end
          seen_employee_ids.add(employee.id)

          item = @pay_period.payroll_items.lock.find_or_initialize_by(employee_id: employee.id)
          if item.persisted? && item.import_source.to_s.start_with?("time_tracking:")
            results[:errors] << { source_user_id: source_user_id, employee_id: employee.id, error: "Employee already has imported time tracking hours in this pay period" }
            next
          end

          if employee.variable_salary? && item.salary_override.to_f <= 0
            results[:errors] << {
              source_user_id: source_user_id,
              employee_id: employee.id,
              error: "Enter this employee's variable salary amount for the pay period before applying time tracking hours."
            }
            next
          end

          persist_mapping!(row, employee)

          if item.new_record?
            item.company_id = @company.id
            item.employment_type = employee.employment_type
            item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
          end
          item.sync_default_payroll_adjustments!(employee)
          preserved_holiday_hours = item.holiday_hours.to_f
          preserved_pto_hours = item.pto_hours.to_f

          hours_error = apply_imported_hours!(
            item,
            employee,
            row,
            override,
            preserved_holiday_hours: preserved_holiday_hours,
            preserved_pto_hours: preserved_pto_hours
          )
          if hours_error.present?
            results[:errors] << { source_user_id: source_user_id, employee_id: employee.id, error: hours_error }
            next
          end

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

        @import.update!(
          status: "applied",
          applied_at: Time.current,
          applied_by: @applied_by,
          negative_adjustment_acknowledgement: finalized_batch? && negative_adjustment_count.positive? ? @negative_adjustment_note : nil
        )
        if finalized_batch?
          acknowledgement = AirePayrollAcknowledgement.record!(
            time_tracking_import: @import,
            status: "imported",
            occurred_at: @import.applied_at
          )
          acknowledgement_ids << acknowledgement.id
        end
      end

      results
    end

    def validate_preview_provenance!
      payload = @import.processed_payload
      if finalized_batch?
        validate_finalized_batch_provenance!(payload)
      elsif payload["validation_version"] != "time_summary_v1" || payload["schema_version"] != PayloadValidator::CONTRACT_VERSION
        raise ArgumentError, "Refresh this time import preview before applying it"
      end

      workweek = @pay_period.resolved_company_workweek
      snapshot = payload["legal_workweek"]
      unless workweek&.confirmed? && workweek.starts_at_minutes.to_i.zero? &&
             snapshot.is_a?(Hash) && snapshot["company_workweek_id"].to_i == workweek.id &&
             snapshot["starts_on_weekday"].to_i == workweek.starts_on_weekday &&
             snapshot["starts_at_minutes"].to_i == workweek.starts_at_minutes &&
             snapshot["timezone"].to_s == workweek.timezone.to_s
        raise ArgumentError, "The legal workweek changed; refresh this time import preview before applying it"
      end

      unless payload["start_date"].to_s == @import.start_date.iso8601 &&
             payload["end_date"].to_s == @import.end_date.iso8601 &&
             @import.start_date >= @pay_period.start_date && @import.end_date <= @pay_period.end_date
        raise ArgumentError, "The pay period dates changed; refresh this time import preview before applying it"
      end
    end

    def validate_finalized_batch_provenance!(payload)
      raw = @import.raw_payload
      PayrollBatchPayloadValidator.new(
        payload: raw,
        start_date: @import.start_date,
        end_date: @import.end_date
      ).validate!
      checksum = raw.dig("export", "checksum")
      unless payload["validation_version"] == BatchImportPreviewService::VALIDATION_VERSION &&
             payload["schema_version"] == PayrollBatchPayloadValidator::CONTRACT_VERSION &&
             payload["batch_id"] == @import.external_batch_id &&
             payload["batch_checksum"] == @import.external_batch_checksum &&
             raw["batch_id"] == @import.external_batch_id &&
             checksum == @import.external_batch_checksum &&
             @import.source_payload_hash == checksum &&
             @import.contract_version == raw["schema_version"] &&
             @import.source_cutoff_at == Time.iso8601(raw.fetch("cutoff_at"))
        raise ArgumentError, "AIRE payroll batch provenance changed; refresh and investigate before applying"
      end
    rescue PayrollBatchPayloadValidator::Error
      raise ArgumentError, "AIRE payroll batch integrity check failed; refresh and investigate before applying"
    end

    def validate_negative_adjustment_acknowledgement!
      return unless finalized_batch? && negative_adjustment_count.positive?
      unless @acknowledge_negative_adjustments && @negative_adjustment_note.length >= 10
        raise ArgumentError, "Review the negative corrections and enter an acknowledgement note of at least 10 characters"
      end
    end

    def negative_adjustment_count
      @import.processed_payload["negative_adjustment_count"].to_i
    end

    def finalized_batch?
      @import.finalized_batch?
    end

    def resolved_warning?(warning, employee_id)
      warning_code = warning.respond_to?(:[]) ? warning["code"] || warning[:code] : nil

      case warning_code
      when "unmatched_employee"
        employee_id.present?
      when "unmapped_wage_rate"
        # Wage-rate mappings are supplied at apply time, so the stale preview warning
        # should not block before build_wage_rate_entries can validate the mapping.
        true
      else
        false
      end
    end

    def apply_imported_hours!(item, employee, row, override, preserved_holiday_hours:, preserved_pto_hours:)
      if finalized_batch? && [ row["total_hours"], row["regular_hours"], row["overtime_hours"] ].any? { |value| value.to_d.negative? }
        return "This AIRE correction produces negative payroll hour totals; use the payroll correction workflow instead."
      end

      categories = Array(row["categories"] || row[:categories]).select do |category|
        finalized_batch? ? category_total_hours(category).nonzero? : category_total_hours(category).positive?
      end
      active_rates = employee.active_wage_rates.to_a
      if finalized_batch? && finalized_payroll_gross_delta(categories, active_rates, override).negative?
        return "This AIRE correction produces a negative Cornerstone payroll gross adjustment; use the payroll correction workflow instead."
      end
      uses_multi_rate = (employee.hourly? || employee.contractor_hourly?) && categories.any? &&
                        (finalized_batch? || active_rates.length > 1)

      unless uses_multi_rate
        item.clear_wage_rate_hours!
        item.hours_worked = row["regular_hours"].to_f
        item.overtime_hours = row["overtime_hours"].to_f
        item.holiday_hours = preserved_holiday_hours
        item.pto_hours = preserved_pto_hours
        return nil
      end

      entries_or_error = if finalized_batch?
        build_finalized_batch_wage_rate_entries(
          item,
          categories,
          active_rates,
          override,
          preserved_holiday_hours: preserved_holiday_hours,
          preserved_pto_hours: preserved_pto_hours
        )
      else
        build_wage_rate_entries(
          item,
          categories,
          active_rates,
          override,
          preserved_holiday_hours: preserved_holiday_hours,
          preserved_pto_hours: preserved_pto_hours
        )
      end
      return entries_or_error if entries_or_error.is_a?(String)

      item.wage_rate_hours = entries_or_error
      item.hours_worked = entries_or_error.sum { |entry| entry[:regular_hours].to_f }
      item.overtime_hours = entries_or_error.sum { |entry| entry[:overtime_hours].to_f }
      item.holiday_hours = entries_or_error.sum { |entry| entry[:holiday_hours].to_f }
      item.pto_hours = entries_or_error.sum { |entry| entry[:pto_hours].to_f }
      nil
    end

    def build_finalized_batch_wage_rate_entries(item, categories, active_rates, override, preserved_holiday_hours:, preserved_pto_hours:)
      override_by_category_key = wage_rate_overrides_by_category_key(override)
      hours_by_dimension = Hash.new { |hash, key| hash[key] = { regular_hours: 0.0, overtime_hours: 0.0 } }

      categories.each do |category|
        rate = wage_rate_for_category(category, active_rates, override_by_category_key)
        return "Map #{category_name(category)} to one of this employee's payroll earning types before importing." unless rate

        source_kind = Array(category["source_kinds"] || category[:source_kinds]).first || "current"
        original_work_dates = Array(category["original_work_dates"] || category[:original_work_dates]).map(&:to_s).sort
        bucket = hours_by_dimension[[ rate.id, source_kind, original_work_dates.first, original_work_dates.last ]]
        bucket[:regular_hours] += category_regular_hours(category)
        bucket[:overtime_hours] += category_overtime_hours(category)
      end

      preserved_by_rate_id = finalized_preserved_hours_by_rate_id(
        item,
        active_rates,
        preserved_holiday_hours: preserved_holiday_hours,
        preserved_pto_hours: preserved_pto_hours
      )
      rates_by_id = active_rates.index_by(&:id)
      dimensions = hours_by_dimension.keys.sort_by { |rate_id, source_kind, first_date, _last_date| [ rate_id, source_kind, first_date.to_s ] }
      primary_rate_ids = Set.new
      entries = dimensions.map do |(rate_id, source_kind, first_date, last_date)|
        rate = rates_by_id.fetch(rate_id)
        preserved = preserved_by_rate_id.delete(rate_id) || { holiday_hours: 0.0, pto_hours: 0.0 }
        imported = hours_by_dimension.fetch([ rate_id, source_kind, first_date, last_date ])
        is_primary = rate.is_primary && primary_rate_ids.add?(rate.id)
        {
          employee_wage_rate_id: rate.id,
          label: finalized_rate_label(rate, source_kind: source_kind, first_date: first_date, last_date: last_date),
          rate: rate.rate.to_f,
          regular_hours: round_hours(imported[:regular_hours]),
          overtime_hours: round_hours(imported[:overtime_hours]),
          holiday_hours: round_hours(preserved[:holiday_hours]),
          pto_hours: round_hours(preserved[:pto_hours]),
          is_primary: is_primary,
          active: rate.active
        }
      end

      preserved_by_rate_id.each do |rate_id, preserved|
        next if preserved.values.all?(&:zero?)

        rate = rates_by_id.fetch(rate_id)
        entries << {
          employee_wage_rate_id: rate.id,
          label: rate.label,
          rate: rate.rate.to_f,
          regular_hours: 0.0,
          overtime_hours: 0.0,
          holiday_hours: round_hours(preserved[:holiday_hours]),
          pto_hours: round_hours(preserved[:pto_hours]),
          is_primary: rate.is_primary,
          active: rate.active
        }
      end

      entries
    end

    def finalized_preserved_hours_by_rate_id(item, active_rates, preserved_holiday_hours:, preserved_pto_hours:)
      active_rate_ids = active_rates.map(&:id).to_set
      preserved = Hash.new { |hash, key| hash[key] = { holiday_hours: 0.0, pto_hours: 0.0 } }
      item.wage_rate_hours.each do |entry|
        rate_id = entry["employee_wage_rate_id"].presence&.to_i
        next unless active_rate_ids.include?(rate_id)

        preserved[rate_id][:holiday_hours] += entry["holiday_hours"].to_f
        preserved[rate_id][:pto_hours] += entry["pto_hours"].to_f
      end

      preservation_rate = active_rates.find(&:is_primary) || active_rates.first
      if preservation_rate
        preserved[preservation_rate.id][:holiday_hours] += [
          preserved_holiday_hours.to_f - preserved.values.sum { |hours| hours[:holiday_hours] },
          0.0
        ].max
        preserved[preservation_rate.id][:pto_hours] += [
          preserved_pto_hours.to_f - preserved.values.sum { |hours| hours[:pto_hours] },
          0.0
        ].max
      end
      preserved
    end

    def finalized_rate_label(rate, source_kind:, first_date:, last_date:)
      provenance = case source_kind
      when "carryover"
        "carryover from #{date_range_label(first_date, last_date)}"
      when "correction"
        "correction for #{date_range_label(first_date, last_date)}"
      else
        "current period"
      end
      "#{rate.label} · AIRE #{provenance} · $#{format('%.2f', rate.rate.to_f)}/hr"
    end

    def date_range_label(first_date, last_date)
      return "prior period" if first_date.blank?

      first = Date.iso8601(first_date)
      last = Date.iso8601(last_date.presence || first_date)
      return first.strftime("%b %-d, %Y") if first == last

      "#{first.strftime('%b %-d')}–#{last.strftime('%b %-d, %Y')}"
    rescue Date::Error
      first_date.to_s
    end

    def build_wage_rate_entries(item, categories, active_rates, override, preserved_holiday_hours:, preserved_pto_hours:)
      override_by_category_key = wage_rate_overrides_by_category_key(override)
      existing_by_rate_id = item.wage_rate_hours.index_by { |entry| entry["employee_wage_rate_id"].presence&.to_i }
      category_hours_by_rate_id = Hash.new { |hash, key| hash[key] = { regular_hours: 0.0, overtime_hours: 0.0 } }
      preserved_scalar_hours = preserved_scalar_hours_by_rate_id(
        existing_by_rate_id,
        active_rates,
        preserved_holiday_hours: preserved_holiday_hours,
        preserved_pto_hours: preserved_pto_hours
      )

      categories.each do |category|
        rate = wage_rate_for_category(category, active_rates, override_by_category_key)
        return "Map #{category_name(category)} to one of this employee's payroll earning types before importing." unless rate

        bucket = category_hours_by_rate_id[rate.id]
        bucket[:regular_hours] += category_regular_hours(category)
        bucket[:overtime_hours] += category_overtime_hours(category)
      end

      active_rates.map do |rate|
        existing = existing_by_rate_id[rate.id] || {}
        imported = category_hours_by_rate_id[rate.id]
        preserved_scalar = preserved_scalar_hours[rate.id]
        {
          employee_wage_rate_id: rate.id,
          label: rate.label,
          rate: rate.rate.to_f,
          regular_hours: round_hours(imported[:regular_hours]),
          overtime_hours: round_hours(imported[:overtime_hours]),
          holiday_hours: round_hours(existing["holiday_hours"].to_f + preserved_scalar[:holiday_hours]),
          pto_hours: round_hours(existing["pto_hours"].to_f + preserved_scalar[:pto_hours]),
          is_primary: rate.is_primary,
          active: rate.active
        }
      end
    end

    def preserved_scalar_hours_by_rate_id(existing_by_rate_id, active_rates, preserved_holiday_hours:, preserved_pto_hours:)
      preservation_rate = active_rates.find(&:is_primary) || active_rates.first
      active_rate_ids = active_rates.map(&:id)
      retained_existing_entries = existing_by_rate_id.slice(*active_rate_ids).values
      existing_holiday_hours = retained_existing_entries.sum { |entry| entry["holiday_hours"].to_f }
      existing_pto_hours = retained_existing_entries.sum { |entry| entry["pto_hours"].to_f }
      holiday_remainder = [ preserved_holiday_hours.to_f - existing_holiday_hours, 0.0 ].max
      pto_remainder = [ preserved_pto_hours.to_f - existing_pto_hours, 0.0 ].max

      Hash.new { |hash, key| hash[key] = { holiday_hours: 0.0, pto_hours: 0.0 } }.tap do |hours_by_rate_id|
        if preservation_rate.present?
          hours_by_rate_id[preservation_rate.id] = {
            holiday_hours: holiday_remainder,
            pto_hours: pto_remainder
          }
        end
      end
    end

    def wage_rate_overrides_by_category_key(override)
      Array(override[:wage_rate_mappings] || override["wage_rate_mappings"]).each_with_object({}) do |mapping, acc|
        mapping = mapping.to_unsafe_h if mapping.respond_to?(:to_unsafe_h)
        mapping = mapping.to_h if mapping.respond_to?(:to_h)
        rate_id = mapping["employee_wage_rate_id"] || mapping[:employee_wage_rate_id]
        next if rate_id.blank?

        effective_rate_cents = mapping["source_effective_rate_cents"] || mapping[:source_effective_rate_cents]
        identity = mapping_identity(
          mapping["source_category_id"] || mapping[:source_category_id],
          mapping["source_category_key"] || mapping[:source_category_key],
          mapping["source_category_name"] || mapping[:source_category_name],
          effective_rate_cents,
          mapping["source_kind"] || mapping[:source_kind]
        )
        acc[identity] = rate_id.to_i if identity.present?

        if effective_rate_cents.blank?
          [
            mapping["source_category_id"] || mapping[:source_category_id],
            mapping["source_category_key"] || mapping[:source_category_key],
            mapping["source_category_name"] || mapping[:source_category_name]
          ].compact_blank.each do |value|
            acc[normalize_match_key(value)] = rate_id.to_i
          end
        end
      end
    end

    def wage_rate_for_category(category, active_rates, override_by_category_key)
      override_rate_id = category_override_keys(category).filter_map { |key| override_by_category_key[key] }.first
      return active_rates.find { |rate| rate.id == override_rate_id } if override_rate_id.present?

      preview_rate_id = category["employee_wage_rate_id"] || category[:employee_wage_rate_id]
      matched = active_rates.find { |rate| rate.id == preview_rate_id.to_i } if preview_rate_id.present?
      return matched if matched

      label_match = label_wage_rate_for_category(category, active_rates)
      return label_match if label_match

      effective_rate_cents = category["effective_rate_cents"] || category[:effective_rate_cents]
      return if finalized_batch? || effective_rate_cents.blank?

      matches_by_rate = active_rates.select { |rate| wage_rate_cents(rate) == effective_rate_cents.to_i }
      matches_by_rate.one? ? matches_by_rate.first : nil
    end

    def wage_rate_cents(rate)
      return if rate.rate.nil?

      (BigDecimal(rate.rate.to_s) * 100).round.to_i
    rescue ArgumentError
      nil
    end

    def category_override_keys(category)
      identity = mapping_identity(
        category["source_category_id"] || category[:source_category_id],
        category["key"] || category[:key],
        category["name"] || category[:name],
        category["effective_rate_cents"] || category[:effective_rate_cents],
        Array(category["source_kinds"] || category[:source_kinds]).join(",")
      )
      [ identity ] + [
        category["source_category_id"] || category[:source_category_id],
        category["key"] || category[:key],
        category["name"] || category[:name]
      ].compact_blank.map { |value| normalize_match_key(value) }
    end

    def label_wage_rate_for_category(category, active_rates)
      candidates = wage_rate_label_candidates(category)
      matches = active_rates.select do |rate|
        rate_key = normalize_match_key(rate.label)
        candidates.any? { |candidate| candidate == rate_key || source_prefixed_candidate_matches_rate?(candidate, rate_key) }
      end

      matches.one? ? matches.first : nil
    end

    def wage_rate_label_candidates(category)
      [ category["key"] || category[:key], category["name"] || category[:name] ]
        .compact_blank
        .map { |value| normalize_match_key(value) }
        .reject(&:blank?)
        .uniq
    end

    def source_prefixed_candidate_matches_rate?(candidate, rate_key)
      candidate_tokens = candidate.split
      rate_tokens = rate_key.split
      return false if rate_tokens.length < 2
      return false if candidate_tokens.length <= rate_tokens.length

      candidate_tokens.last(rate_tokens.length) == rate_tokens
    end

    def category_total_hours(category)
      (category["total_hours"] || category[:total_hours] || category["hours"] || category[:hours]).to_f
    end

    def category_regular_hours(category)
      (category["regular_hours"] || category[:regular_hours]).to_f
    end

    def category_overtime_hours(category)
      (category["overtime_hours"] || category[:overtime_hours]).to_f
    end

    def category_name(category)
      category["name"] || category[:name] || "this source category"
    end

    def finalized_payroll_gross_delta(categories, active_rates, override)
      override_by_category_key = wage_rate_overrides_by_category_key(override)
      categories.sum do |category|
        wage_rate = wage_rate_for_category(category, active_rates, override_by_category_key)
        next 0.to_d unless wage_rate

        rate = wage_rate.rate.to_d
        (category_regular_hours(category).to_d * rate) +
          (category_overtime_hours(category).to_d * rate * BigDecimal("1.5"))
      end
    end

    def normalize_match_key(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def mapping_identity(source_category_id, source_category_key, source_category_name, effective_rate_cents, source_kind = nil)
      values = [ source_category_id, source_category_key, source_category_name ].map { |value| normalize_match_key(value) }
      return if values.all?(&:blank?)

      [ values.join("|"), (effective_rate_cents unless finalized_batch?), normalize_match_key(source_kind) ].compact_blank.join("|")
    end

    def round_hours(value)
      BigDecimal(value.to_s).round(2).to_f
    end

    def import_source_key
      suffix = finalized_batch? ? ":#{@import.external_batch_id}" : nil
      "time_tracking:#{@source.source_type}:#{@source.id}#{suffix}"
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
