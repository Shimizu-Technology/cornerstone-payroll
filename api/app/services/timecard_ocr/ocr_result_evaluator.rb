module TimecardOcr
  class OcrResultEvaluator
    REPEATED_PATTERN_TOLERANCE_MINUTES = 4

    def self.score(payload)
      new(payload).score
    end

    def self.acceptable?(payload)
      new(payload).acceptable?
    end

    def self.needs_stronger_review?(payload)
      new(payload).needs_stronger_review?
    end

    def initialize(payload)
      @payload = payload || {}
      @entries = Array(@payload["entries"])
    end

    def score
      total = 0
      total += employee_name_score
      total += 4 if @payload["period_start"].present? && @payload["period_end"].present?
      total += @entries.count { |entry| entry["card_day"].present? } * 2
      total += @entries.count { |entry| entry["date"].present? } * 2
      total += punch_rows.count * 4
      total += complete_rows.count * 3
      total += (@entries.sum { |entry| entry["confidence"].to_f } * 10).round
      total -= anomaly_penalty
      total
    end

    def acceptable?
      employee_name_plausible? &&
        @payload["period_start"].present? &&
        @payload["period_end"].present? &&
        punch_rows.count >= 3 &&
        complete_rows.count >= 2 &&
        average_confidence >= 0.7 &&
        critical_note_count.zero? &&
        repeated_work_pattern_count.zero?
    end

    def needs_stronger_review?
      !acceptable? || duplicate_workday_count.positive? || repeated_work_pattern_count.positive?
    end

    private

    def employee_name_score
      return 0 unless @payload["employee_name"].present?

      total = 1
      total += 2 if employee_name_plausible?
      total += 1 if @payload["employee_name"].to_s.split.size >= 2
      total
    end

    def employee_name_plausible?
      name = @payload["employee_name"].to_s.strip
      return false if name.blank?

      tokens = name.split
      tokens.size >= 2 && name.match?(/\A[[:alpha:]'. -]+\z/)
    end

    def punch_rows
      @punch_rows ||= @entries.select do |entry|
        %w[clock_in lunch_out lunch_in clock_out].any? { |field| entry[field].present? }
      end
    end

    def complete_rows
      @complete_rows ||= @entries.select do |entry|
        entry["clock_in"].present? && entry["clock_out"].present?
      end
    end

    def average_confidence
      return 0.0 if @entries.empty?
      @entries.sum { |entry| entry["confidence"].to_f } / @entries.size
    end

    def critical_note_count
      @entries.count do |entry|
        notes = entry["notes"].to_s.downcase
        notes.include?("verify lunch punches or row alignment") ||
          notes.include?("repeated worked-row pattern") ||
          notes.include?("suspicious rounded digit read")
      end
    end

    def duplicate_workday_count
      complete_rows
        .sort_by { |entry| entry["card_day"].to_i }
        .each_cons(2)
        .count do |left, right|
          right["card_day"].to_i == left["card_day"].to_i + 1 &&
            similar_work_pattern?(left, right)
        end
    end

    def repeated_work_pattern_count
      worked_pattern_groups.count
    end

    def worked_pattern_groups
      groups = []
      remaining = complete_rows.select { |entry| comparable_work_pattern?(entry) }.dup

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
      %w[clock_in lunch_out lunch_in clock_out].all? { |field| entry[field].present? }
    end

    def similar_work_pattern?(left, right)
      comparable_work_pattern?(left) &&
        comparable_work_pattern?(right) &&
        %w[clock_in lunch_out lunch_in clock_out].all? do |field|
          (parse_minutes(left[field]) - parse_minutes(right[field])).abs <= REPEATED_PATTERN_TOLERANCE_MINUTES
        end
    end

    def parse_minutes(value)
      hour, minute = value.to_s.split(":").map(&:to_i)
      (hour * 60) + minute
    end

    def anomaly_penalty
      penalty = @entries.sum do |entry|
        notes = entry["notes"].to_s.downcase
        entry_penalty = 0
        entry_penalty += 3 if notes.include?("missing date")
        entry_penalty += 2 if notes.include?("missing clock_in") || notes.include?("missing clock_out")
        entry_penalty += 2 if notes.include?("missing lunch pair")
        entry_penalty += 4 if notes.include?("verify lunch punches or row alignment")
        entry_penalty += 5 if notes.include?("repeated worked-row pattern")
        entry_penalty += 4 if notes.include?("suspicious rounded digit read")
        entry_penalty += 1 if notes.include?("low confidence")
        entry_penalty += 2 if entry["card_day"].blank?
        entry_penalty
      end
      penalty += duplicate_workday_count * 3
      penalty += repeated_work_pattern_count * 6
      penalty
    end
  end
end
