module TimecardOcr
  class OcrDigitConsistencyService
    CONFUSION_PAIRS = Set.new([
      Set[0, 3], Set[0, 6], Set[0, 8],
      Set[1, 4], Set[1, 7],
      Set[3, 5], Set[3, 7], Set[3, 8], Set[3, 9],
      Set[4, 5],
      Set[5, 6], Set[5, 9],
      Set[6, 9]
    ]).freeze

    PUNCH_FIELDS = %w[clock_in lunch_out lunch_in clock_out in3 out3].freeze
    REASONABLE_CLOCK_IN_RANGE  = (5..14).freeze
    REASONABLE_CLOCK_OUT_RANGE = (12..18).freeze

    def self.correct(raw_result)
      new(raw_result).correct
    end

    def initialize(raw_result)
      @result = raw_result
      @entries = Array(@result["entries"]).map(&:dup)
    end

    def correct
      correct_same_field_outliers
      correct_unreasonable_hours
      @result.merge("entries" => @entries)
    end

    private

    def correct_same_field_outliers
      PUNCH_FIELDS.each do |field|
        valued = @entries.select { |e| e[field].present? }
        next if valued.size < 2

        by_hour = valued.group_by { |e| hour_of(e[field]) }
        by_hour.each_value do |group|
          next if group.size < 2
          correct_minute_outliers(field, group)
        end
      end
    end

    def correct_minute_outliers(field, group)
      minute_freq = group.each_with_object(Hash.new(0)) do |entry, counts|
        counts[minute_of(entry[field])] += 1
      end

      group.each do |entry|
        current_min = minute_of(entry[field])
        hour = hour_of(entry[field])

        best = best_confusion_alternative(field, group, current_min, minute_freq)
        next unless best

        old_value = entry[field]
        new_value = format("%02d:%02d", hour, best)
        entry[field] = new_value
        entry["notes"] = merge_notes(entry["notes"], "digit-corrected #{field}: #{old_value} → #{new_value}")

        minute_freq[current_min] -= 1
        minute_freq[best] += 1
      end
    end

    def best_confusion_alternative(field, group, current_min, minute_freq)
      alternatives = minute_confusion_alternatives(current_min)
        .select { |alt| minute_freq[alt].to_i > 0 }

      return nil if alternatives.empty?

      alternatives
        .select { |alt| should_prefer?(field, group, alt, current_min, minute_freq) }
        .max_by { |alt| [minute_freq[alt], avg_confidence_for_minute(field, group, alt)] }
    end

    def should_prefer?(field, group, candidate, current, freq)
      candidate_count = freq[candidate]
      current_count = freq[current]

      return true if candidate_count > current_count
      return false if candidate_count < current_count

      avg_confidence_for_minute(field, group, candidate) -
        avg_confidence_for_minute(field, group, current) >= 0.05
    end

    def correct_unreasonable_hours
      correct_hour_outliers("clock_in", REASONABLE_CLOCK_IN_RANGE)
      correct_hour_outliers("clock_out", REASONABLE_CLOCK_OUT_RANGE)
    end

    def correct_hour_outliers(field, reasonable_range)
      valued = @entries.select { |e| e[field].present? }
      return if valued.size < 2

      hours = valued.map { |e| hour_of(e[field]) }
      median = sorted_median(hours)

      valued.each do |entry|
        hour = hour_of(entry[field])
        next if reasonable_range.cover?(hour)

        candidates = reasonable_range.select { |h| hour_digit_confused?(hour, h) }
        best = candidates.min_by { |h| (h - median).abs }
        next unless best

        minute = minute_of(entry[field])
        old_value = entry[field]
        new_value = format("%02d:%02d", best, minute)
        entry[field] = new_value
        entry["notes"] = merge_notes(entry["notes"], "digit-corrected #{field} hour: #{old_value} → #{new_value}")
      end
    end

    def minute_confusion_alternatives(minute)
      tens, ones = minute.divmod(10)
      alts = []

      confusion_partners(tens).each do |alt_tens|
        alt = alt_tens * 10 + ones
        alts << alt if alt.between?(0, 59)
      end

      confusion_partners(ones).each do |alt_ones|
        alt = tens * 10 + alt_ones
        alts << alt if alt.between?(0, 59)
      end

      alts.uniq
    end

    def confusion_partners(digit)
      CONFUSION_PAIRS.each_with_object([]) do |pair, out|
        out.concat(pair.to_a.reject { |d| d == digit }) if pair.include?(digit)
      end.uniq
    end

    def hour_digit_confused?(a, b)
      return false if a == b
      a_tens, a_ones = a.divmod(10)
      b_tens, b_ones = b.divmod(10)

      (a_tens == b_tens && digit_confused?(a_ones, b_ones)) ||
        (a_ones == b_ones && digit_confused?(a_tens, b_tens))
    end

    def digit_confused?(a, b)
      return false if a == b
      CONFUSION_PAIRS.include?(Set[a, b])
    end

    def hour_of(time_str)   = time_str.split(":").first.to_i
    def minute_of(time_str) = time_str.split(":").last.to_i

    def avg_confidence_for_minute(field, group, minute)
      matching = group.select { |e| minute_of(e[field]) == minute }
      return 0.0 if matching.empty?
      matching.sum { |e| e["confidence"].to_f } / matching.size
    end

    def sorted_median(values)
      s = values.sort
      mid = s.size / 2
      s.size.odd? ? s[mid] : (s[mid - 1] + s[mid]) / 2.0
    end

    def merge_notes(existing, new_note)
      [existing, new_note].compact_blank.join("; ").presence
    end
  end
end
