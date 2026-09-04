# frozen_string_literal: true

module TimeTracking
  class ReconcileCommittedImportService
    def initialize(import:, mappings:, reconciled_by:, reconciliation_note:)
      @import = import
      @mappings = Array(mappings)
      @actor = reconciled_by
      @note = reconciliation_note.to_s.strip
      @pay_period = import.pay_period
      @company = @pay_period.company
      @source = import.time_tracking_source
    end

    def call
      raise ArgumentError, "Historical reconciliation requires a committed pay period" unless pay_period.committed?
      raise ArgumentError, "Enter a reconciliation note of at least 10 characters" if note.length < 10

      ids = { batch: [], entries: [] }
      results = pay_period.with_lock { reconcile_locked!(ids) }
      AirePayrollAcknowledgement.dispatch_pending!(ids: ids[:batch])
      AirePayrollEntryAcknowledgement.dispatch_pending!(ids: ids[:entries])
      results
    end

    private

    attr_reader :import, :mappings, :actor, :note, :pay_period, :company, :source

    def reconcile_locked!(ids)
      import.with_lock(requires_new: true) do
        raise ArgumentError, "Only a previewed finalized AIRE batch can be reconciled" unless import.status == "previewed" && import.finalized_batch?
        validate_provenance!

        rows = Array(import.processed_payload.fetch("rows"))
        mapping_by_source_id = mappings.index_by { |mapping| value(mapping, :source_user_id).to_s }
        seen_employee_ids = Set.new
        linked = []

        rows.each do |row|
          source_user_id = row.fetch("source_user_id").to_s
          employee_id = value(mapping_by_source_id[source_user_id] || {}, :employee_id).presence&.to_i || row["employee_id"].presence&.to_i
          raise ArgumentError, "Map every AIRE employee before reconciling" unless employee_id
          raise ArgumentError, "The same payroll employee cannot be linked to two AIRE employees" unless seen_employee_ids.add?(employee_id)

          employee = Employee.active.find_by(id: employee_id, company_id: company.id)
          raise ArgumentError, "Mapped payroll employee was not found or is inactive" unless employee
          item = pay_period.payroll_items.find_by(employee_id: employee.id)
          raise ArgumentError, "#{employee.full_name} does not have a payroll item in this committed period" unless item
          validate_hours!(item, row, employee)
          persist_mapping!(row, employee)
          EntryAllocationRecorder.new(
            time_tracking_import: import,
            payroll_item: item,
            source_employee: source_employee_for(source_user_id)
          ).call
          linked << { employee_id: employee.id, employee_name: employee.full_name, payroll_item_id: item.id }
        end

        import.update!(
          status: "applied",
          applied_at: Time.current,
          applied_by: actor,
          reconciled_at: Time.current,
          reconciled_by: actor,
          reconciliation_note: note
        )
        ids[:batch] << AirePayrollAcknowledgement.record!(
          time_tracking_import: import,
          status: "committed",
          occurred_at: pay_period.committed_at || import.reconciled_at
        ).id
        ids[:entries].concat(record_entry_lifecycle!.map(&:id))

        { reconciled: linked, errors: [] }
      end
    end

    def validate_provenance!
      raw = import.raw_payload
      PayrollBatchPayloadValidator.new(payload: raw, start_date: import.start_date, end_date: import.end_date).validate!
      checksum = raw.dig("export", "checksum")
      valid = import.processed_payload["validation_version"] == BatchImportPreviewService::VALIDATION_VERSION &&
        import.external_batch_id == raw["batch_id"] && import.external_batch_checksum == checksum &&
        import.source_payload_hash == checksum && import.contract_version == raw["schema_version"]
      raise ArgumentError, "AIRE payroll batch provenance changed; refresh and investigate" unless valid
    rescue PayrollBatchPayloadValidator::Error
      raise ArgumentError, "AIRE payroll batch integrity check failed; refresh and investigate"
    end

    def validate_hours!(item, row, employee)
      expected_regular = BigDecimal(row.fetch("regular_hours").to_s).round(2)
      expected_overtime = BigDecimal(row.fetch("overtime_hours").to_s).round(2)
      actual_regular = item.hours_worked.to_d.round(2)
      actual_overtime = item.overtime_hours.to_d.round(2)
      return if actual_regular == expected_regular && actual_overtime == expected_overtime

      raise ArgumentError,
            "#{employee.full_name} does not reconcile: Cornerstone has #{format('%.2f', actual_regular)} regular / #{format('%.2f', actual_overtime)} overtime hours, " \
            "but AIRE has #{format('%.2f', expected_regular)} regular / #{format('%.2f', expected_overtime)}"
    end

    def persist_mapping!(row, employee)
      source_user_uuid = row["source_user_uuid"].presence
      mapping = TimeTrackingEmployeeMapping.resolve_source_identity!(
        company: company,
        source: source,
        source_user_id: row.fetch("source_user_id"),
        source_user_uuid: source_user_uuid
      )
      mapping ||= TimeTrackingEmployeeMapping.new(company: company, time_tracking_source: source)
      mapping.update!(
        employee: employee,
        source_user_id: row.fetch("source_user_id").to_s,
        source_user_uuid: source_user_uuid,
        source_email: row["source_email"],
        source_display_name: row["source_display_name"]
      )
    end

    def record_entry_lifecycle!
      acknowledgements = AirePayrollEntryAcknowledgement.record_for_import!(
        time_tracking_import: import,
        status: "committed",
        occurred_at: pay_period.committed_at || import.reconciled_at,
        source_event_prefix: "reconciliation"
      )
      payment_acknowledgements = pay_period.payroll_items.flat_map do |item|
        status = { "printed" => "payment_prepared", "delivered" => "payment_issued", "voided" => "payment_voided" }[item.check_status]
        next [] unless status && item.time_tracking_entry_allocations.where(time_tracking_import: import).exists?

        event = item.check_events.order(:created_at, :id).last
        AirePayrollEntryAcknowledgement.record_for_import!(
          time_tracking_import: import,
          status: status,
          occurred_at: event&.created_at || import.reconciled_at,
          payment_method: "paper_check",
          payment_reference: item.check_number,
          source_event_prefix: "reconciliation_payment_#{item.id}",
          payroll_item_id: item.id
        )
      end
      acknowledgements + payment_acknowledgements
    end

    def source_employee_for(source_user_id)
      @source_employees ||= Array(import.raw_payload.fetch("employees")).index_by { |employee| employee.fetch("source_user_id").to_s }
      @source_employees.fetch(source_user_id)
    end

    def value(hash, key)
      hash[key] || hash[key.to_s]
    end
  end
end
