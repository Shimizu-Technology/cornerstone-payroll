module TimecardOcr
  class ReviewSummary
    def self.build(timecard)
      new(timecard).build
    end

    def initialize(timecard)
      @timecard = timecard
      @entries = timecard.punch_entries.to_a
    end

    def build
      {
        "severity" => severity,
        "priority_rank" => priority_rank,
        "attention_count" => unresolved_attention_entries.count,
        "approved_attention_count" => approved_attention_entries.count,
        "low_confidence_count" => unresolved_low_confidence_entries.count,
        "noted_entry_count" => unresolved_noted_entries.count,
        "missing_punch_count" => unresolved_missing_punch_entries.count,
        "manual_edit_count" => manual_edit_entries.count,
        "reason_codes" => reason_codes
      }
    end

    private

    def severity
      return "critical" if @timecard.failed?
      return "warning" if @timecard.complete? && reason_codes.include?("awaiting_review")
      return "critical" if unresolved_missing_punch_entries.any?
      return "warning" if unresolved_low_confidence_entries.any? || unresolved_noted_entries.any? || unresolved_attention_entries.any? || manual_edit_entries.any?
      return "info" if @timecard.pending? || @timecard.processing?

      "ok"
    end

    def priority_rank
      case severity
      when "critical" then 0
      when "warning" then 1
      when "info" then 2
      else 3
      end
    end

    def reason_codes
      reasons = []
      reasons << "ocr_failed" if @timecard.failed?
      reasons << "awaiting_review" if @timecard.complete?
      reasons << "missing_punches" if unresolved_missing_punch_entries.any?
      reasons << "low_confidence" if unresolved_low_confidence_entries.any?
      reasons << "ocr_notes" if unresolved_noted_entries.any?
      reasons << "manual_edits" if manual_edit_entries.any?
      reasons << "approved_anomalies" if approved_attention_entries.any?
      reasons << "processing" if @timecard.pending? || @timecard.processing?
      reasons
    end

    def unresolved_attention_entries
      @unresolved_attention_entries ||= @entries.select { |entry| entry.unresolved? && entry.needs_attention? }
    end

    def approved_attention_entries
      @approved_attention_entries ||= @entries.select { |entry| entry.approved? && entry.needs_attention? }
    end

    def unresolved_low_confidence_entries
      @unresolved_low_confidence_entries ||= @entries.select { |entry| entry.unresolved? && entry.low_confidence? }
    end

    def unresolved_noted_entries
      @unresolved_noted_entries ||= @entries.select { |entry| entry.unresolved? && entry.notes.present? && !entry.blank_day? }
    end

    def unresolved_missing_punch_entries
      @unresolved_missing_punch_entries ||= @entries.select { |entry| entry.unresolved? && entry.missing_core_punch? }
    end

    def manual_edit_entries
      @manual_edit_entries ||= @entries.select { |entry| entry.manually_edited && !entry.blank_day? }
    end
  end
end
