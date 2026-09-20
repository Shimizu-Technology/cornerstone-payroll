# frozen_string_literal: true

module AirePayrollCalendar
  # Read-only comparison of the immutable AIRE cutoff with Cornerstone payment evidence.
  # A committed allocation is deliberately not counted as paid until payment is confirmed.
  class PostLockComparison
    class Error < StandardError; end

    def initialize(pay_period:, source:, client: nil)
      @pay_period = pay_period
      @source = source
      @client = client || TimeTracking::Client.new(source)
    end

    def call
      event = pay_period.aire_payroll_calendar_period&.payroll_events&.verified&.order(:id)&.last
      raise Error, "AIRE has not delivered a verified final cutoff for this pay period" unless event

      batch = @client.payroll_batch(batch_id: event.payroll_batch_id)
      TimeTracking::PayrollBatchPayloadValidator.new(
        payload: batch, start_date: pay_period.start_date, end_date: pay_period.end_date,
        allow_legacy_uncategorized: pay_period.committed?
      ).validate!
      unless batch["batch_id"] == event.payroll_batch_id &&
             ActiveSupport::SecurityUtils.secure_compare(batch.dig("export", "checksum"), event.payroll_batch_checksum)
        raise Error, "AIRE's final hours no longer match the verified cutoff. Do not use this comparison."
      end

      rows = final_rows(batch) + allocation_rows(batch) + held_rows(batch)
      {
        batch_id: event.payroll_batch_id,
        cutoff_at: batch.fetch("cutoff_at"),
        verified_at: event.verified_at&.iso8601,
        summary: summary(rows),
        rows: rows.sort_by { |row| [ row.fetch(:employee_name), row.fetch(:work_date), row.fetch(:source_time_entry_id), row.fetch(:status) ] }
      }
    rescue TimeTracking::Client::Error, TimeTracking::PayrollBatchPayloadValidator::Error => e
      raise Error, "Could not verify the final AIRE hours: #{e.message}"
    end

    private

    attr_reader :pay_period, :source

    def final_rows(batch)
      batch.fetch("employees").flat_map do |person|
        Array(person.fetch("adjustments")).filter_map do |adjustment|
          regular = BigDecimal(adjustment.fetch("regular_hours").to_s)
          overtime = BigDecimal(adjustment.fetch("overtime_hours").to_s)
          next if regular.zero? && overtime.zero?

          status = regular.negative? || overtime.negative? ? "correction" : "owed"
          base_row(person, adjustment, status: status, regular: regular, overtime: overtime)
        end
      end
    end

    def held_rows(batch)
      batch.fetch("exclusions").map do |exclusion|
        base_row(exclusion, exclusion, status: "held",
                 regular: BigDecimal(exclusion.fetch("held_regular_hours").to_s),
                 overtime: BigDecimal(exclusion.fetch("held_overtime_hours").to_s),
                 reason: exclusion.fetch("reason"))
      end
    end

    def allocation_rows(batch)
      final_entries = batch.fetch("employees").flat_map do |person|
        Array(person.fetch("adjustments")).map do |adjustment|
          [ adjustment.fetch("source_time_entry_id").to_s, person["source_user_uuid"], adjustment.fetch("original_work_date") ]
        end
      end
      final_by_id = final_entries.group_by(&:first)
      source_entry_ids = final_by_id.keys + batch.fetch("exclusions").map { |row| row.fetch("source_time_entry_id").to_s }
      period_ids = TimeTrackingManualAllocation.where(time_tracking_source: source, pay_period: pay_period).select(:id)
      scope = TimeTrackingManualAllocation.where(time_tracking_source: source)
        .where(original_work_date: pay_period.start_date..pay_period.end_date)
        .or(TimeTrackingManualAllocation.where(time_tracking_source: source, id: period_ids))
      if source_entry_ids.any?
        scope = scope.or(TimeTrackingManualAllocation.where(time_tracking_source: source,
                                                            source_time_entry_id: source_entry_ids.uniq))
      end
      scope = scope.distinct
        .includes(:employee, :payroll_item)
      scope.filter_map do |allocation|
        next if allocation.status == "voided"

        final_identity = final_by_id[allocation.source_time_entry_id.to_s]
        mismatched = final_identity.present? && final_identity.none? do |(_id, uuid, work_date)|
          TimeTrackingEmployeeMapping.normalize_uuid(uuid) == allocation.source_user_uuid &&
            work_date == allocation.original_work_date.iso8601
        end
        status = if mismatched
          "mismatch"
        elsif allocation.status == "issued"
          "paid"
        else
          "awaiting_payment"
        end
        {
          employee_name: allocation.employee.full_name,
          employee_id: allocation.employee_id,
          source_user_uuid: allocation.source_user_uuid,
          source_time_entry_id: allocation.source_time_entry_id.to_s,
          work_date: allocation.original_work_date.iso8601,
          source_kind: "linked_payroll",
          status: status,
          regular_hours: allocation.regular_hours.to_f,
          overtime_hours: allocation.overtime_hours.to_f,
          payroll_item_id: allocation.payroll_item_id,
          pay_period_id: allocation.pay_period_id,
          payment_method: allocation.payroll_item.effective_payment_delivery_method,
          payment_reference: (allocation.payroll_item.check_number if status == "paid"),
          reason: ("AIRE entry identity or work date differs from its payroll link" if mismatched)
        }.compact
      end
    end

    def base_row(person, entry, status:, regular:, overtime:, reason: nil)
      uuid = TimeTrackingEmployeeMapping.normalize_uuid(person["source_user_uuid"])
      mapping = mappings_by_uuid[uuid] || mappings_by_id[person["source_user_id"].to_s]
      {
        employee_name: mapping&.employee&.full_name || person["display_name"].presence || "AIRE person ##{person['source_user_id']}",
        employee_id: mapping&.employee_id,
        source_user_uuid: uuid,
        source_time_entry_id: entry.fetch("source_time_entry_id").to_s,
        work_date: entry.fetch("original_work_date"),
        source_kind: entry["source_kind"] || "held",
        status: status,
        regular_hours: regular.to_f,
        overtime_hours: overtime.to_f,
        reason: reason,
        mapping_status: mapping ? (mapping.employee.active? ? "mapped" : "inactive") : "unmapped"
      }.compact
    end

    def mappings_by_uuid
      @mappings_by_uuid ||= mappings.index_by { |mapping| TimeTrackingEmployeeMapping.normalize_uuid(mapping.source_user_uuid) }
    end

    def mappings_by_id
      @mappings_by_id ||= mappings.index_by { |mapping| mapping.source_user_id.to_s }
    end

    def mappings
      @mappings ||= source.time_tracking_employee_mappings.includes(:employee).to_a
    end

    def summary(rows)
      totals = rows.group_by { |row| row.fetch(:status) }.transform_values do |group|
        {
          regular_hours: group.sum { |row| BigDecimal(row.fetch(:regular_hours).to_s) }.to_f,
          overtime_hours: group.sum { |row| BigDecimal(row.fetch(:overtime_hours).to_s) }.to_f,
          entry_count: group.size
        }
      end
      %w[paid awaiting_payment owed held correction mismatch].each do |status|
        totals[status] ||= { regular_hours: 0.0, overtime_hours: 0.0, entry_count: 0 }
      end
      totals.merge(
        needs_attention: rows.any? { |row| row.fetch(:status) != "paid" || row[:mapping_status] == "unmapped" },
        unmapped_count: rows.count { |row| row[:mapping_status] == "unmapped" }
      )
    end
  end
end
