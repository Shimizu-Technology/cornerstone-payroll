# frozen_string_literal: true

module TimeTracking
  class ExclusionSummary
    CATEGORIES = {
      "pending_approval" => :needs_action,
      "pending_overtime" => :needs_action,
      "open_clock" => :needs_action,
      "denied_approval" => :not_paid_by_decision,
      "denied_overtime" => :not_paid_by_decision,
      "approved_after_cutoff" => :next_payroll,
      "created_after_cutoff" => :next_payroll,
      "overtime_approved_after_cutoff" => :next_payroll,
      "pending_payment_attestation" => :payment_evidence_pending,
      "payment_attested_pending_evidence" => :payment_evidence_pending,
      "payment_evidence_pending" => :payment_evidence_pending
    }.freeze

    def self.category(reason)
      CATEGORIES.fetch(reason, :needs_action)
    end

    def self.call(exclusions)
      buckets = CATEGORIES.values.uniq.index_with { { entry_count: 0, total_hours: 0.to_d } }
      total_hours = 0
      exclusions.each do |exclusion|
        hours = decimal(exclusion["held_total_hours"])
        total_hours += hours
        bucket = buckets.fetch(category(exclusion["reason"]))
        bucket[:entry_count] += 1 unless hours.zero?
        bucket[:total_hours] += hours
      end
      {
        entry_count: exclusions.length,
        total_hours: total_hours,
        by_category: buckets,
        actionable_entry_count: buckets.fetch(:needs_action).fetch(:entry_count)
      }
    end

    def self.decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      0.to_d
    end
    private_class_method :decimal
  end
end
