module TimecardOcr
  class OcrResponseNormalizer
    DAY_NAMES = {
      "mon" => "Mon", "monday" => "Mon",
      "tue" => "Tue", "tues" => "Tue", "tuesday" => "Tue",
      "wed" => "Wed", "wednesday" => "Wed",
      "thu" => "Thu", "thur" => "Thu", "thurs" => "Thu", "thursday" => "Thu",
      "fri" => "Fri", "friday" => "Fri",
      "sat" => "Sat", "saturday" => "Sat",
      "sun" => "Sun", "sunday" => "Sun"
    }.freeze

    TIME_SUFFIX_PATTERN = /([ap])\z/i
    PERIOD_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
    REPEATED_PATTERN_TOLERANCE_MINUTES = 4
    ROUNDED_DRIFT_MINUTES = [0, 30].freeze
    ROUNDED_DRIFT_DELTA_MINUTES = 10
    ROUNDED_DRIFT_COMPARISON_WINDOW_MINUTES = 30
    ROUNDED_DRIFT_MIN_COMPARABLE_ROWS = 2

    def self.normalize(payload = nil, reference_date: Time.zone.today, **payload_keywords)
      normalized_payload = payload || payload_keywords
      new(normalized_payload, reference_date: reference_date).normalize
    end

    def initialize(payload, reference_date: nil)
      @payload = payload || {}
      @reference_date = reference_date&.to_date || Time.zone.today
    end

    def normalize
      period_start = normalize_date(@payload["period_start"])
      period_end = normalize_date(@payload["period_end"])
      period_start, period_end, period_year_corrected = reconcile_period_years(period_start, period_end)
      employee_name = normalize_employee_name(@payload["employee_name"])
      entries = Array(@payload["entries"]).map do |entry|
        normalize_entry(entry || {}, period_start, period_end)
      end
      repeated_pattern_rows = apply_repeated_pattern_flags!(entries)
      rounded_drift_rows = apply_rounded_digit_drift_flags!(entries)

      {
        "employee_name" => employee_name,
        "period_start" => period_start,
        "period_end" => period_end,
        "entries" => entries,
        "overall_confidence" => normalize_overall_confidence(
          @payload["overall_confidence"],
          entries,
          employee_name,
          period_year_corrected,
          repeated_pattern_rows,
          rounded_drift_rows
        )
      }
    end

    private

    def normalize_entry(entry, period_start, period_end)
      card_day = normalize_card_day(entry["card_day"] || entry["date"])
      normalized_date = normalize_entry_date(entry["date"], card_day, period_start, period_end)
      normalized = {
        "card_day" => card_day,
        "date" => normalized_date,
        "day_of_week" => normalize_day_of_week(entry["day_of_week"], normalized_date),
        "clock_in" => normalize_time(entry["clock_in"]),
        "lunch_out" => normalize_time(entry["lunch_out"]),
        "lunch_in" => normalize_time(entry["lunch_in"]),
        "clock_out" => normalize_time(entry["clock_out"]),
        "in3" => normalize_time(entry["in3"]),
        "out3" => normalize_time(entry["out3"]),
        "confidence" => normalize_confidence(entry["confidence"]),
        "notes" => normalize_notes(entry["notes"])
      }

      repair_ambiguous_times!(normalized, entry)
      normalize_punch_structure!(normalized)

      anomalies = anomaly_notes(normalized, period_start, period_end)
      normalized["notes"] = merge_notes(normalized["notes"], anomalies)
      apply_confidence_penalties!(normalized, anomalies)
      normalized
    end

    def normalize_employee_name(value)
      cleaned = value.to_s.gsub(/[^\p{Alnum}\s'.-]/, " ").squish
      cleaned = cleaned.sub(/\A(name|employee)\s+/i, "").sub(/\s+(name|employee)\z/i, "").squish
      cleaned.presence
    end

    def normalize_date(value)
      return nil if value.blank?
      return value if value.is_a?(String) && value.match?(PERIOD_PATTERN)

      Date.parse(value.to_s).iso8601
    rescue Date::Error
      nil
    end

    def reconcile_period_years(period_start, period_end)
      return [period_start, period_end, false] unless @reference_date

      start_date = period_start.present? ? Date.iso8601(period_start) : nil
      end_date = period_end.present? ? Date.iso8601(period_end) : nil
      extracted_years = [start_date&.year, end_date&.year].compact

      return [period_start, period_end, false] if extracted_years.empty?
      return [period_start, period_end, false] if extracted_years.all? { |year| (year - @reference_date.year).abs <= 1 }

      if start_date && end_date
        corrected_start, corrected_end = best_year_pair(start_date, end_date)
        return [corrected_start.iso8601, corrected_end.iso8601, true]
      end

      corrected_date = best_single_year(start_date || end_date)
      if start_date
        [corrected_date.iso8601, period_end, true]
      else
        [period_start, corrected_date.iso8601, true]
      end
    rescue Date::Error
      [period_start, period_end, false]
    end

    def normalize_entry_date(value, card_day, period_start, period_end)
      return normalize_card_day_date(period_start, period_end, card_day) if card_day
      return normalize_card_day_date(period_start, period_end, value) if value.is_a?(Integer)
      return normalize_date(value) if value.to_s.match?(PERIOD_PATTERN)

      day_number = normalize_card_day(value)
      return normalize_card_day_date(period_start, period_end, day_number) if day_number

      normalize_date(value)
    rescue Date::Error
      nil
    end

    def normalize_card_day(value)
      return nil if value.blank?

      day_number = value.to_s[/\d+/]&.to_i
      return nil unless day_number&.between?(1, 31)

      day_number
    end

    def normalize_card_day_date(period_start, period_end, day_number)
      return nil unless day_number && period_start

      start_date = Date.iso8601(period_start)
      end_date = period_end ? Date.iso8601(period_end) : start_date.end_of_month

      candidate = adjust_candidate_day(day_number, start_date, end_date)
      return candidate.iso8601 if candidate && candidate >= start_date && candidate <= end_date

      nil
    rescue Date::Error
      nil
    end

    def adjust_candidate_day(day_number, start_date, end_date)
      candidate = Date.new(start_date.year, start_date.month, day_number)
      return candidate if candidate >= start_date && candidate <= end_date

      if candidate < start_date
        next_month = start_date >> 1
        candidate = Date.new(next_month.year, next_month.month, day_number)
        return candidate if candidate <= end_date
      end

      nil
    rescue Date::Error
      nil
    end

    def normalize_day_of_week(value, normalized_date)
      mapped = DAY_NAMES[value.to_s.strip.downcase]
      return mapped if mapped.present?
      return nil if normalized_date.blank?

      Date.iso8601(normalized_date).strftime("%a")
    end

    def normalize_time(value)
      raw = value.to_s.strip
      return nil if raw.blank? || raw.downcase == "null"

      compact = raw.upcase.gsub(/\s+/, "")
      compact = compact.sub(/\./, "")
      compact = compact.gsub(/[^0-9:AP]/, "")
      compact = compact.sub(TIME_SUFFIX_PATTERN, '\1M')

      normalized =
        case compact
        when /\A\d{1,2}\z/
          "#{compact.rjust(2, '0')}:00"
        when /\A\d{3,4}\z/
          digits = compact.rjust(4, "0")
          "#{digits[0, 2]}:#{digits[2, 2]}"
        when /\A\d{1,2}:\d{2}\z/
          compact
        when /\A\d{1,2}(?::\d{2})?[AP]M\z/
          Time.strptime(compact, compact.include?(":") ? "%I:%M%p" : "%I%p").strftime("%H:%M")
        when /\A\d{3,4}[AP]M\z/
          digits = compact.delete_suffix("AM").delete_suffix("PM")
          suffix = compact[-2, 2]
          Time.strptime("#{digits.rjust(4, '0')}#{suffix}", "%I%M%p").strftime("%H:%M")
        else
          Time.parse(compact).strftime("%H:%M")
        end

      hour, minute = normalized.split(":").map(&:to_i)
      return nil unless hour.between?(0, 23) && minute.between?(0, 59)

      format("%02d:%02d", hour, minute)
    rescue ArgumentError
      nil
    end

    def normalize_confidence(value)
      number = value.to_f
      return 0.0 if value.blank? && !value.is_a?(Numeric)

      number.clamp(0.0, 1.0).round(2)
    end

    ERROR_NOTE_PATTERNS = %w[
      missing\ clock_in
      missing\ clock_out
      missing\ lunch\ pair
      missing\ date
      clock_out\ earlier\ than\ clock_in
      lunch_in\ earlier\ than\ lunch_out
      date\ outside\ pay\ period
      verify\ lunch\ punches\ or\ row\ alignment
    ].freeze

    def normalize_overall_confidence(value, entries, employee_name, period_year_corrected, _repeated_pattern_rows, _rounded_drift_rows)
      rows_with_data = entries.select { |e| %w[clock_in clock_out].any? { |f| e[f].present? } }
      return 0.0 if rows_with_data.empty? && value.blank?

      confidence =
        if rows_with_data.any?
          rows_with_data.sum { |e| e["confidence"].to_f } / rows_with_data.size
        elsif value.present?
          normalize_confidence(value)
        else
          0.0
        end

      impossible_order_count = entries.count do |entry|
        entry["notes"].to_s.include?("clock_out earlier than clock_in") ||
          entry["notes"].to_s.include?("lunch_in earlier than lunch_out")
      end

      error_row_count = entries.count do |entry|
        notes = entry["notes"].to_s
        ERROR_NOTE_PATTERNS.any? { |pat| notes.include?(pat) }
      end

      confidence = [confidence, 0.75].min if employee_name.blank?
      confidence = [confidence, 0.8].min if period_year_corrected
      confidence -= 0.02 * error_row_count
      confidence -= 0.05 * impossible_order_count
      confidence.clamp(0.0, 1.0).round(2)
    end

    def normalize_notes(value)
      value.to_s.strip.presence
    end

    def anomaly_notes(entry, period_start, period_end)
      notes = []
      punch_count = [entry["clock_in"], entry["lunch_out"], entry["lunch_in"], entry["clock_out"], entry["in3"], entry["out3"]].count(&:present?)
      blank_day = punch_count.zero? && entry["notes"].blank?

      return notes if blank_day

      notes << "missing clock_in" if punch_count.positive? && entry["clock_in"].blank?
      final_out = entry["out3"].presence || entry["clock_out"]
      notes << "missing clock_out" if punch_count.positive? && final_out.blank?
      notes << "missing lunch pair" if partial_lunch_pair?(entry)
      notes << "missing date" if entry["date"].blank?
      notes << "low confidence" if entry["confidence"].to_f < 0.7
      notes << "verify lunch punches or row alignment" if suspicious_long_shift_without_lunch?(entry)

      if entry["clock_in"].present? && entry["clock_out"].present? && entry["clock_out"] < entry["clock_in"]
        notes << "clock_out earlier than clock_in"
      end

      if entry["lunch_out"].present? && entry["lunch_in"].present? && entry["lunch_in"] < entry["lunch_out"]
        notes << "lunch_in earlier than lunch_out"
      end

      if period_start.present? && period_end.present? && entry["date"].present?
        date = Date.iso8601(entry["date"])
        notes << "date outside pay period" if date < Date.iso8601(period_start) || date > Date.iso8601(period_end)
      end

      notes
    end

    def apply_confidence_penalties!(entry, anomalies)
      confidence = entry["confidence"].to_f
      confidence = [confidence, 0.55].min if anomalies.any? { |note| note.include?("missing clock_in") || note.include?("missing clock_out") }
      confidence = [confidence, 0.65].min if anomalies.include?("missing lunch pair")
      confidence = [confidence, 0.6].min if anomalies.include?("verify lunch punches or row alignment")
      entry["confidence"] = confidence.round(2)
    end

    def repair_ambiguous_times!(normalized, raw_entry)
      repair_to_pm!(normalized, raw_entry["lunch_out"], "lunch_out", after: normalized["clock_in"])
      repair_to_pm!(normalized, raw_entry["lunch_in"], "lunch_in", after: normalized["lunch_out"] || normalized["clock_in"])
      repair_to_pm!(normalized, raw_entry["clock_out"], "clock_out", after: normalized["lunch_in"] || normalized["lunch_out"] || normalized["clock_in"])
      repair_to_pm!(normalized, raw_entry["in3"], "in3", after: normalized["clock_out"] || normalized["lunch_in"])
      repair_to_pm!(normalized, raw_entry["out3"], "out3", after: normalized["in3"] || normalized["clock_out"])
    end

    def normalize_punch_structure!(entry)
      all_punches = [entry["clock_in"], entry["lunch_out"], entry["lunch_in"], entry["clock_out"], entry["in3"], entry["out3"]].compact
      return entry unless all_punches.size == 2

      entry["clock_in"] = all_punches.first
      entry["lunch_out"] = nil
      entry["lunch_in"] = nil
      entry["clock_out"] = all_punches.last
      entry["in3"] = nil
      entry["out3"] = nil
      entry
    end

    def partial_lunch_pair?(entry)
      entry["lunch_out"].present? ^ entry["lunch_in"].present?
    end

    def suspicious_long_shift_without_lunch?(entry)
      return false unless entry["clock_in"].present?
      final_out = entry["out3"].presence || entry["clock_out"]
      return false unless final_out.present?
      return false if entry["lunch_out"].present? || entry["lunch_in"].present?

      span_minutes = parse_minutes(final_out) - parse_minutes(entry["clock_in"])
      span_minutes >= 360
    end

    def repair_to_pm!(entry, raw_value, field, after:)
      return unless ambiguous_time?(raw_value)
      return if entry[field].blank? || after.blank?
      return unless parse_minutes(entry[field]) < parse_minutes(after)
      return if entry[field].start_with?("12:")

      entry[field] = add_twelve_hours(entry[field])
    end

    def ambiguous_time?(value)
      raw = value.to_s.strip
      raw.present? && !raw.match?(/[AP](?:M)?/i)
    end

    def add_twelve_hours(value)
      hour, minute = value.split(":").map(&:to_i)
      hour += 12 if hour < 12
      format("%02d:%02d", hour, minute)
    end

    def parse_minutes(value)
      hour, minute = value.to_s.split(":").map(&:to_i)
      (hour * 60) + minute
    end

    def apply_repeated_pattern_flags!(entries)
      repeated_groups = worked_pattern_groups(entries)
      repeated_rows = repeated_groups.flat_map do |group|
        group.map do |entry|
          entry["notes"] = merge_notes(entry["notes"], ["repeated worked-row pattern; verify OCR"])
          entry
        end
      end
      repeated_rows.count
    end

    def apply_rounded_digit_drift_flags!(entries)
      flagged = []

      entries.each do |entry|
        next unless suspicious_rounded_outer_punches?(entry)
        flag_suspicious_rounded_digit!(entry, flagged)
      end

      %w[clock_in lunch_out lunch_in clock_out in3 out3].each do |field|
        rows_with_field = entries.select { |entry| rounded_drift_candidate?(entry, field) }
        rows_with_field.each do |entry|
          next unless suspicious_rounded_minute?(entry[field])

          comparisons = comparable_field_rows(rows_with_field, entry, field)
          next if comparisons.size < ROUNDED_DRIFT_MIN_COMPARABLE_ROWS

          comparison_minutes = comparisons.map { |other| minute_value(other[field]) }
          next if comparison_minutes.empty?
          next if comparison_minutes.all? { |minute| ROUNDED_DRIFT_MINUTES.include?(minute) }

          if (minute_value(entry[field]) - median(comparison_minutes)).abs >= ROUNDED_DRIFT_DELTA_MINUTES
            flag_suspicious_rounded_digit!(entry, flagged)
          end
        end
      end

      flagged.uniq.count
    end

    CORE_PUNCH_FIELDS = %w[clock_in lunch_out lunch_in clock_out].freeze
    ALL_PUNCH_FIELDS = %w[clock_in lunch_out lunch_in clock_out in3 out3].freeze

    def row_fingerprint(entry)
      return nil if entry["notes"].to_s.include?("verify lunch punches or row alignment")
      return nil unless CORE_PUNCH_FIELDS.all? { |field| entry[field].present? }

      CORE_PUNCH_FIELDS.map { |field| entry[field] }.join("|")
    end

    def worked_pattern_groups(entries)
      groups = []
      remaining = entries.select { |entry| comparable_work_pattern?(entry) }.dup

      until remaining.empty?
        seed = remaining.shift
        group = [seed]

        loop do
          matching, rest = remaining.partition do |entry|
            group.any? { |member| similar_work_pattern?(member, entry) }
          end
          break if matching.empty?

          group.concat(matching)
          remaining = rest
        end

        groups << group if group.size >= 3
      end

      groups
    end

    def comparable_work_pattern?(entry)
      row_fingerprint(entry).present?
    end

    def similar_work_pattern?(left, right)
      comparable_work_pattern?(left) &&
        comparable_work_pattern?(right) &&
        CORE_PUNCH_FIELDS.all? do |field|
          (parse_minutes(left[field]) - parse_minutes(right[field])).abs <= REPEATED_PATTERN_TOLERANCE_MINUTES
        end
    end

    def comparable_field_rows(rows, target_entry, field)
      target_minutes = parse_minutes(target_entry[field])
      target_hour = target_entry[field].split(":").first.to_i

      rows.reject { |entry| entry.equal?(target_entry) }.select do |entry|
        entry_hour = entry[field].split(":").first.to_i
        entry_minutes = parse_minutes(entry[field])
        entry_hour == target_hour && (entry_minutes - target_minutes).abs <= ROUNDED_DRIFT_COMPARISON_WINDOW_MINUTES
      end
    end

    def rounded_drift_candidate?(entry, field)
      entry[field].present? && punch_count(entry) >= 4
    end

    def suspicious_rounded_outer_punches?(entry)
      return false unless punch_count(entry) >= 4
      return false unless CORE_PUNCH_FIELDS.all? { |field| entry[field].present? }

      first_in = entry["clock_in"]
      final_out = entry["out3"].presence || entry["clock_out"]
      outer_minutes = [minute_value(first_in), minute_value(final_out)]
      inner_minutes = [minute_value(entry["lunch_out"]), minute_value(entry["lunch_in"])]

      outer_minutes.all? { |minute| ROUNDED_DRIFT_MINUTES.include?(minute) } &&
        inner_minutes.none? { |minute| ROUNDED_DRIFT_MINUTES.include?(minute) }
    end

    def flag_suspicious_rounded_digit!(entry, flagged)
      entry["notes"] = merge_notes(entry["notes"], ["suspicious rounded digit read; verify handwritten minutes"])
      entry["confidence"] = [entry["confidence"].to_f, 0.78].min.round(2)
      flagged << entry
    end

    def punch_count(entry)
      ALL_PUNCH_FIELDS.count { |field| entry[field].present? }
    end

    def suspicious_rounded_minute?(value)
      ROUNDED_DRIFT_MINUTES.include?(minute_value(value))
    end

    def minute_value(value)
      value.to_s.split(":").last.to_i
    end

    def median(values)
      sorted = values.sort
      midpoint = sorted.length / 2
      return sorted[midpoint] if sorted.length.odd?

      (sorted[midpoint - 1] + sorted[midpoint]) / 2.0
    end

    def best_year_pair(start_date, end_date)
      candidate = [@reference_date.year - 1, @reference_date.year, @reference_date.year + 1].filter_map do |year|
        candidate_start = change_year(start_date, year)
        candidate_end = change_year(end_date, year_rollover?(start_date, end_date) ? year + 1 : year)
        next unless candidate_start && candidate_end

        midpoint = candidate_start + ((candidate_end - candidate_start) / 2)
        { start: candidate_start, end: candidate_end, distance: (midpoint - @reference_date).abs }
      end.min_by { |item| item[:distance] }

      [candidate[:start], candidate[:end]]
    end

    def best_single_year(date)
      [@reference_date.year - 1, @reference_date.year, @reference_date.year + 1]
        .filter_map { |year| change_year(date, year) }
        .min_by { |candidate| (candidate - @reference_date).abs }
    end

    def change_year(date, year)
      Date.new(year, date.month, date.day)
    rescue Date::Error
      nil
    end

    def year_rollover?(start_date, end_date)
      end_date.month < start_date.month || (end_date.month == start_date.month && end_date.day < start_date.day)
    end

    def merge_notes(existing, generated)
      notes = [existing, *generated]
        .compact
        .flat_map { |value| value.to_s.split(/\s*;\s*/) }
        .map(&:strip)
        .reject(&:empty?)
        .uniq
      notes.join("; ").presence
    end
  end
end
