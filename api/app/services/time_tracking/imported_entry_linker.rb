# frozen_string_literal: true

module TimeTracking
  # Creates pending exact-entry AIRE links from an applied pre-pay snapshot.
  # Remote acknowledgement is dispatched only after the payroll transaction
  # commits, and AIRE does not mark the hours paid until payment evidence exists.
  class ImportedEntryLinker
    def initialize(pay_period:, actor:)
      @pay_period = pay_period
      @actor = actor
    end

    def call!
      imports = pay_period.time_tracking_imports.where(status: "applied").to_a.select(&:live_snapshot?)
      imports.flat_map { |import| link_import!(import) }
    end

    private

    attr_reader :pay_period, :actor

    def link_import!(import)
      raise ArgumentError, "Payroll operator is required for AIRE payment tracking" unless actor

      versions = source_versions(import)
      lines = import.time_tracking_entry_allocations.includes(:payroll_item).to_a
      lines.group_by(&:payroll_item).each do |item, item_lines|
        if item.effective_payment_delivery_method == "direct_deposit"
          raise ArgumentError, "AIRE direct-deposit hours need bank-settlement confirmation before committing this payroll"
        end
        unless item.hours_worked.to_d.round(2) == item_lines.sum(&:regular_hours).to_d.round(2) &&
               item.overtime_hours.to_d.round(2) == item_lines.sum(&:overtime_hours).to_d.round(2)
          raise ArgumentError, "Payroll hours changed after AIRE import. Refresh the snapshot and recalculate before committing."
        end
      end
      lines.group_by do |line|
        [ line.payroll_item_id, line.source_time_entry_id ]
      end.filter_map do |(_item_id, entry_id), lines|
        item = lines.first.payroll_item
        entry_versions = lines.map { |line| versions.fetch([ entry_id, line.line_key ]) }.uniq
        raise ArgumentError, "AIRE source entry versions disagree within this snapshot" unless entry_versions.one?

        version = entry_versions.first
        uuid = TimeTrackingEmployeeMapping.normalize_uuid(lines.first.source_user_uuid)
        mapping = import.time_tracking_source.time_tracking_employee_mappings.find_by(source_user_uuid: uuid)
        unless mapping&.employee_id == item.employee_id &&
               lines.all? { |line| line.source_user_uuid == uuid && line.original_work_date == lines.first.original_work_date }
          raise ArgumentError, "AIRE identity or work date changed after this snapshot was applied"
        end

        regular = lines.sum(&:regular_hours).to_d.round(2)
        overtime = lines.sum(&:overtime_hours).to_d.round(2)
        next if (regular + overtime).zero?

        existing = TimeTrackingManualAllocation.find_by(
          time_tracking_source: import.time_tracking_source,
          source_time_entry_id: entry_id,
          payroll_item: item
        )
        next existing.id if existing

        TimeTrackingManualAllocation.create!(
          company: pay_period.company,
          time_tracking_source: import.time_tracking_source,
          pay_period: pay_period,
          payroll_item: item,
          employee: item.employee,
          created_by: actor,
          source_user_uuid: uuid,
          source_time_entry_id: entry_id,
          source_time_entry_version: version,
          original_work_date: lines.first.original_work_date,
          regular_hours: regular,
          overtime_hours: overtime,
          reconciliation_note: "Exact AIRE pre-pay snapshot #{import.id} (#{import.source_payload_hash})"
        ).id
      end
    end

    def source_versions(import)
      Array(import.raw_payload["employees"]).each_with_object({}) do |employee, result|
        Array(employee["adjustments"]).each do |adjustment|
          result[[ adjustment.fetch("source_time_entry_id").to_s, adjustment.fetch("line_key").to_s ]] =
            Integer(adjustment.fetch("source_time_entry_version"))
        end
      end
    end
  end
end
