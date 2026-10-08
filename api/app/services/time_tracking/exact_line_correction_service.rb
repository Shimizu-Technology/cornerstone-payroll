# frozen_string_literal: true

module TimeTracking
  class ExactLineCorrectionService
    PURPOSE = "time_tracking_exact_accounting_correction"

    def initialize(import:, source_user_id:, source_time_entry_id:, line_key:, actor:)
      @import = import
      @source = import.time_tracking_source
      @actor = actor
      @identity = [ source_user_id.to_s, source_time_entry_id.to_s, line_key.to_s ]
    end

    def preview
      context = validated_context!
      money = financial_preview(context)
      proof = proof_digest(context, money)
      {
        preview_token: verifier.generate({ "import_id" => @import.id, "actor_id" => @actor.id,
          "identity" => @identity, "proof_digest" => proof }, purpose: PURPOSE, expires_in: 15.minutes),
        proof_digest: proof, source_user_id: @identity[0], source_time_entry_id: @identity[1], line_key: @identity[2],
        original_source_time_entry_version: frozen_line(context[:allocation].time_tracking_import, context[:allocation])["source_time_entry_version"],
        source_change: context[:line], **context[:line].slice("total_hours", "regular_hours", "overtime_hours").symbolize_keys, original_pay_period_id: context[:original].pay_period_id,
        original_payroll_item_id: context[:original].id, original_check_number: context[:original].check_number,
        employee_name: context[:original].employee.full_name, pay_date: @import.pay_period.pay_date,
        original: money[:original], corrected: money[:corrected], deltas: money[:deltas],
        accounting_only: true
      }
    end

    def confirm!(preview_token:, reason:, acknowledge_accounting_only:)
      token = verifier.verified(preview_token.to_s, purpose: PURPOSE)
      unless token && token["import_id"] == @import.id && token["actor_id"] == @actor.id && token["identity"] == @identity
        raise ArgumentError, "Correction preview expired or belongs to another operator; review it again"
      end
      reason = reason.to_s.strip
      unless ActiveModel::Type::Boolean.new.cast(acknowledge_accounting_only) && reason.length >= 10
        raise ArgumentError, "Acknowledge no new payment or recovery and enter a reason of at least 10 characters"
      end
      validate_actor!
      disposition = nil
      @import.pay_period.with_lock do
        @source.lock!
        @actor.lock!
        validate_actor!
        @import.lock!
        # The exact line is a stable idempotency key. A crash after commit can
        # replay the same signed preview without creating another supplemental.
        disposition = existing_disposition
        if disposition
          disposition.verified!
          raise ArgumentError, "Correction preview does not match the committed disposition" unless disposition.proof_digest == token["proof_digest"]
          next
        end
        context = validated_context!
        context[:original].pay_period.lock!
        context[:original].lock!
        context = validated_context!
        money = financial_preview(context)
        proof = proof_digest(context, money)
        raise ArgumentError, "Source or payroll history changed; review the accounting correction again" unless proof == token["proof_digest"]
        period, item = IssueCorrectivePaycheckService.issue!(
          original_pay_period: context[:original].pay_period, employee: context[:original].employee,
          corrected_inputs: context[:inputs], pay_date: @import.pay_period.pay_date,
          reason: reason, actor: @actor)
        disposition = TimeTrackingCorrectionDisposition.create!(
          company_id: @source.company_id, time_tracking_source: @source, time_tracking_import: @import,
          original_allocation: context[:allocation], corrective_payroll_item: item, created_by: @actor,
          source_instance_id: @source.expected_source_instance_id, batch_id: @import.external_batch_id,
          batch_checksum: @import.external_batch_checksum, source_user_id: @identity[0],
          source_user_uuid: context[:employee]["source_user_uuid"], source_time_entry_id: @identity[1],
          line_key: @identity[2], source_kind: "correction", line_snapshot: context[:line], proof_digest: proof,
          reason: reason, **context[:line].slice("total_hours", "regular_hours", "overtime_hours").symbolize_keys)
        event_id = "cornerstone:accounting-correction:#{SecureRandom.uuid}"
        TimeTrackingCorrectionReceipt.create!(time_tracking_correction_disposition: disposition,
          event_id: event_id, payload: receipt_payload(disposition, period, item, event_id))
      end
      ActiveRecord.after_all_transactions_commit { disposition.time_tracking_correction_receipt.dispatch! }
      disposition
    rescue IssueCorrectivePaycheckService::CorrectionError => e
      raise ArgumentError, e.message
    end

    private

    def existing_disposition
      TimeTrackingCorrectionDisposition.find_by(time_tracking_source: @source,
        source_instance_id: @source.expected_source_instance_id, batch_id: @import.external_batch_id,
        source_user_id: @identity[0], source_time_entry_id: @identity[1], line_key: @identity[2])
    end

    def validate_actor!
      @actor.reload
      unless @actor.active? && @actor.can_access_company?(@source.company_id) && StaffRolePolicy.allowed?(@actor, :payroll_operations)
        raise ArgumentError, "Operator no longer has payroll access to this company"
      end
    end

    def validated_context!
      validate_actor!
      raise ArgumentError, "Only an editable previewed finalized import can resolve a correction" unless @import.finalized_batch? && @import.status == "previewed" && @import.pay_period.can_edit?
      raise ArgumentError, "Source ownership or availability changed" unless @source.active? && @source.company_id == @import.pay_period.company_id && @actor&.active?
      @source.connector.require!(:finalized_batch_v2)
      @source.connector.require!(:exact_line_receipts_v2)
      raise ArgumentError, "Verify this source installation and approve historical reconciliation first" unless @source.remote_identity_pinned? && @source.historical_reconciliation_complete?
      validate_batch!(@import)
      remote = Client.new(@source).payroll_batch(batch_id: @import.external_batch_id)
      PayrollBatchPayloadValidator.new(payload: remote, start_date: @import.start_date,
        end_date: @import.end_date, expected_source: @source.connector.source_identifier).validate!
      remote_identity = ConnectionIdentity.validate!(source: @source, payload: remote)
      unless remote_identity.source_instance_id == @source.expected_source_instance_id &&
        remote.dig("export", "checksum") == @import.external_batch_checksum &&
        CanonicalPayload.checksum(remote.except("export")) == CanonicalPayload.checksum(@import.raw_payload.except("export"))
        raise ArgumentError, "The frozen source batch changed; investigate before resolving this correction"
      end
      employee = Array(@import.raw_payload["employees"]).find { |row| row["source_user_id"].to_s == @identity[0] }
      line = Array(employee&.dig("adjustments")).find { |row| row["source_time_entry_id"].to_s == @identity[1] && row["line_key"].to_s == @identity[2] }
      unless line && employee["source_user_uuid"].present? && Array(employee["adjustments"]).one? &&
        line["source_kind"] == "correction" && line["total_hours"].to_d.negative? &&
        line["regular_hours"].to_d <= 0 && line["overtime_hours"].to_d <= 0
        raise ArgumentError, "Review requires one exact negative correction line for this employee; mixed corrections need manual review"
      end
      allocations = TimeTrackingEntryAllocation.where(company_id: @source.company_id, time_tracking_source_id: @source.id,
        source_user_id: @identity[0], source_user_uuid: employee["source_user_uuid"], source_time_entry_id: @identity[1], line_key: @identity[2]).to_a
      raise ArgumentError, "The exact original allocation is missing or ambiguous; reconcile source history first" unless allocations.one?
      allocation = allocations.first
      original = allocation.payroll_item
      validate_batch!(allocation.time_tracking_import)
      original_line = frozen_line(allocation.time_tracking_import, allocation)
      mapping = TimeTrackingEmployeeMapping.find_by(time_tracking_source_id: @source.id, source_user_uuid: employee["source_user_uuid"])
      rates = original.wage_rate_hours
      unless original_line && allocation.source_kind.in?(%w[current carryover]) && original.employment_type == "hourly" &&
        original.pay_period.can_issue_corrective_paycheck? && !original.voided? &&
        allocation.time_tracking_import.status == "applied" &&
        mapping&.employee_id == original.employee_id && mapping.source_user_id == @identity[0] &&
        original.employee.active? && original.employee.hourly? && original.employee.active_wage_rates.count == 1 &&
        rates.size <= 1 && (rates.empty? || single_rate_hours_reconcile?(rates.first, original)) &&
        OriginalAllocationProof.earning_identity(line) == OriginalAllocationProof.earning_identity(original_line) &&
        line["original_work_date"] == original_line["original_work_date"] &&
        %w[total_hours regular_hours overtime_hours].all? { |key| allocation.public_send(key) == original_line[key].to_d }
        raise ArgumentError, "This correction needs review of original identity, category, rate or hours; automatic correction is unavailable"
      end
      original_proof = OriginalAllocationProof.new(payroll_item: original, source: @source,
        source_user_id: @identity[0], source_user_uuid: employee["source_user_uuid"]).call
      payment_proof = OriginalPaymentProof.call(original)
      unless allocation.regular_hours + line["regular_hours"].to_d >= 0 && allocation.overtime_hours + line["overtime_hours"].to_d >= 0
        raise ArgumentError, "Correction exceeds the original source line's REG/OT hours; review other days separately"
      end
      old_version = original_line["source_time_entry_version"]
      new_version = line["source_time_entry_version"]
      if old_version.present? || new_version.present?
        unless old_version.is_a?(Integer) && new_version.is_a?(Integer) && old_version >= 0 && new_version > old_version
          raise ArgumentError, "The exact source entry version is missing or does not advance the original frozen version"
        end
      end
      prior = PayrollItem.joins(:pay_period).where(correction_for_payroll_item_id: original.id).where(pay_periods: { status: "committed" }).not_voided
      raise ArgumentError, "An existing corrective payroll makes this line ambiguous; review cumulative corrections separately" if prior.exists?
      inputs = { hours_worked: original.hours_worked.to_d + line["regular_hours"].to_d,
        overtime_hours: original.overtime_hours.to_d + line["overtime_hours"].to_d }
      raise ArgumentError, "Correction exceeds the original paid hours" if inputs.values.any?(&:negative?)
      { employee: employee, line: line, allocation: allocation, original: original, inputs: inputs,
        original_proof: original_proof[:evidence], payment_proof: payment_proof }
    rescue PayrollBatchPayloadValidator::Error, ConnectionIdentity::Error => e
      raise ArgumentError, e.message
    end

    def single_rate_hours_reconcile?(rate, original)
      id = rate["employee_wage_rate_id"].to_s
      id.match?(/\A[1-9]\d*\z/) && original.employee.employee_wage_rates.where(id: id.to_i).exists? &&
        rate["rate"].to_d == original.pay_rate.to_d &&
        { "regular_hours" => :hours_worked, "overtime_hours" => :overtime_hours,
          "holiday_hours" => :holiday_hours, "pto_hours" => :pto_hours }.all? do |key, field|
          rate[key].to_d == original.public_send(field).to_d
        end
    end

    def validate_batch!(import)
      PayrollBatchPayloadValidator.new(payload: import.raw_payload, start_date: import.start_date,
        end_date: import.end_date, expected_source: @source.connector.source_identifier).validate!
      identity = ConnectionIdentity.validate!(source: @source, payload: import.raw_payload)
      unless identity.source_instance_id == @source.expected_source_instance_id &&
        import.raw_payload.dig("export", "checksum") == import.external_batch_checksum &&
        import.raw_payload["batch_id"] == import.external_batch_id && import.source_payload_hash == import.external_batch_checksum
        raise ArgumentError, "Frozen batch provenance or source installation does not match"
      end
    rescue PayrollBatchPayloadValidator::Error, ConnectionIdentity::Error => e
      raise ArgumentError, e.message
    end

    def frozen_line(import, allocation)
      employee = Array(import.raw_payload["employees"]).find { |row| row["source_user_id"].to_s == allocation.source_user_id && row["source_user_uuid"] == allocation.source_user_uuid }
      Array(employee&.dig("adjustments")).find { |row| row["source_time_entry_id"].to_s == allocation.source_time_entry_id && row["line_key"].to_s == allocation.line_key }
    end

    def financial_preview(context)
      result = IssueCorrectivePaycheckService.preview(original_pay_period: context[:original].pay_period,
        employee: context[:original].employee, corrected_inputs: context[:inputs])
      unless result[:deltas][:gross_pay].to_d.negative? && result[:deltas][:net_pay].to_d.negative? && !result[:meta][:will_generate_check]
        raise ArgumentError, "This line does not produce a negative accounting-only adjustment; review payroll manually"
      end
      result
    end

    def proof_digest(context, money)
      CanonicalPayload.checksum({ import: @import.attributes.slice("id", "pay_period_id", "external_batch_checksum", "source_payload_hash"),
        source: @source.attributes.slice("id", "company_id", "expected_source_instance_id", "connection_uuid", "remote_source_identifier", "base_url"),
        line: context[:line], original: context[:original].attributes, original_period: context[:original].pay_period.attributes,
        original_batches_and_allocations: context[:original_proof], original_payment: context[:payment_proof],
        employee: context[:original].employee.attributes, wage_rates: context[:original].employee.employee_wage_rates.order(:id).map(&:attributes),
        money: money, pay_date: @import.pay_period.pay_date.to_s }.deep_stringify_keys)
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def receipt_payload(disposition, period, item, event_id)
      { batch_id: disposition.batch_id, event_id: event_id, status: "committed", occurred_at: disposition.created_at.iso8601(6),
        external_pay_period_id: period.id.to_s, external_payroll_item_id: item.id.to_s,
        source_time_entry_id: disposition.source_time_entry_id, source_user_uuid: disposition.source_user_uuid,
        contract_version: "2.0", source_line_key: disposition.line_key, source_kind: "correction",
        total_hours: disposition.total_hours.to_s, regular_hours: disposition.regular_hours.to_s, overtime_hours: disposition.overtime_hours.to_s,
        metadata: { accounting_only: true, correction_disposition_id: disposition.id.to_s,
          original_pay_period_id: disposition.original_allocation.pay_period_id.to_s,
          original_payroll_item_id: disposition.original_allocation.payroll_item_id.to_s,
          corrective_pay_period_id: period.id.to_s, corrective_payroll_item_id: item.id.to_s } }
    end
  end
end
