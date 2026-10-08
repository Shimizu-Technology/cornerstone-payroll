# frozen_string_literal: true

module TimeTracking
  class AllocationStatusSummary
    STATUS_BUCKETS = {
      "imported" => :in_payroll,
      "committed" => :in_payroll,
      "payment_prepared" => :payment_pending,
      "payment_issued" => :paid,
      "payment_failed" => :needs_attention,
      "payment_voided" => :needs_attention,
      "payment_cancelled" => :in_payroll
    }.freeze

    def self.call(import)
      new(import).call
    end

    def initialize(import)
      @import = import
    end

    def call
      allocations = import.time_tracking_entry_allocations.to_a
      dispositions = CorrectionCoverage.new(import).dispositions
      accounting = empty_bucket
      dispositions.each { |row| add_allocation!(accounting, row) }
      correction_receipts = dispositions.filter_map(&:time_tracking_correction_receipt)
      latest_by_line = latest_acknowledgements.index_by { |acknowledgement| line_identity(acknowledgement) }
      buckets = %i[in_payroll payment_pending paid needs_attention].index_with { empty_bucket }

      allocations.each do |allocation|
        acknowledgement = latest_by_line[line_identity(allocation)]
        bucket = STATUS_BUCKETS.fetch(acknowledgement&.status, :needs_attention)
        add_allocation!(buckets.fetch(bucket), allocation)
      end

      all_acknowledgements = import.aire_payroll_entry_acknowledgements.to_a + correction_receipts
      {
        line_count: allocations.length + dispositions.length,
        accounting_corrections: accounting,
        total_hours: allocations.sum(&:total_hours) + dispositions.sum(&:total_hours),
        regular_hours: allocations.sum(&:regular_hours) + dispositions.sum(&:regular_hours),
        overtime_hours: allocations.sum(&:overtime_hours) + dispositions.sum(&:overtime_hours),
        in_payroll: buckets.fetch(:in_payroll),
        payment_pending: buckets.fetch(:payment_pending),
        paid: buckets.fetch(:paid),
        needs_attention: buckets.fetch(:needs_attention),
        held: held_summary,
        synchronization: {
          pending_event_count: all_acknowledgements.count { |acknowledgement| acknowledgement.delivered_at.blank? },
          failed_event_count: all_acknowledgements.count { |acknowledgement| acknowledgement.last_error.present? },
          last_confirmed_at: all_acknowledgements.filter_map(&:delivered_at).max
        }
      }
    end

    private

    attr_reader :import

    def latest_acknowledgements
      import.aire_payroll_entry_acknowledgements
        .select(&:line_contract?)
        .group_by { |acknowledgement| line_identity(acknowledgement) }
        .values
        .map { |events| events.max_by { |event| [ event.occurred_at, event.id ] } }
    end

    def line_identity(record)
      [ record.source_time_entry_id.to_s, record.respond_to?(:source_line_key) ? record.source_line_key.to_s : record.line_key.to_s ]
    end

    def empty_bucket
      { line_count: 0, total_hours: 0.to_d, regular_hours: 0.to_d, overtime_hours: 0.to_d }
    end

    def add_allocation!(bucket, allocation)
      bucket[:line_count] += 1
      bucket[:total_hours] += allocation.total_hours
      bucket[:regular_hours] += allocation.regular_hours
      bucket[:overtime_hours] += allocation.overtime_hours
    end

    def held_summary
      exclusions = Array(import.processed_payload["exclusions"])
      {
        entry_count: exclusions.length,
        total_hours: exclusions.sum { |exclusion| decimal(exclusion["held_total_hours"]) }
      }
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      0.to_d
    end
  end
end
