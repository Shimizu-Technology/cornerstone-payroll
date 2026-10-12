# frozen_string_literal: true

module TimeTracking
  class PaymentAttestationResolutionService
    class Error < StandardError; end
    CAPABILITY = "payment_attestation_resolution_v1"
    RECEIPT_ERROR = "The source did not prove the saved reported-payment match. Its hours remain reserved; retry this saved match."

    def initialize(pay_period:, source:, actor:)
      @pay_period, @source, @actor = pay_period, source, actor
    end

    def create!(attestation_id:, source_user_uuid:, payroll_item_id:, expected_version:, reason:)
      authorize!
      source_user_uuid = TimeTrackingEmployeeMapping.normalize_uuid(source_user_uuid)
      explanation = reason.to_s.strip
      raise Error, "Explain this exact payment match in at least 20 characters" if explanation.length < 20
      existing = source.time_tracking_manual_allocations.find_by(source_payment_attestation_id: attestation_id.to_s)
      if existing
        unless existing.created_by_id == actor.id && existing.payroll_item_id.to_s == payroll_item_id.to_s &&
            existing.source_user_uuid == source_user_uuid && existing.reconciliation_note == explanation &&
            existing.payment_resolution_intent["expected_version"].to_s == expected_version.to_s
          raise Error, "This report already has a saved match. Reconcile that original match before changing it."
        end
        sync!(existing) if existing.payment_resolution_pending?
        return existing
      end
      raise Error, "Verify this source's reported-payment resolution capability first" unless source.supports?(CAPABILITY) && source.remote_identity_pinned?
      hold = reports(source_user_uuid).find { |row| row["id"].to_s == attestation_id.to_s }
      unless hold && hold["status"] == "pending_evidence" && hold["source_user_uuid"] == source_user_uuid &&
          hold["version"].is_a?(Integer) && hold["version"].to_s == expected_version.to_s && in_period?(hold["work_date"])
        raise Error, "Refresh the unchanged reported payment in this work period before matching it"
      end
      context = hold["resolution_context"]
      unless context.is_a?(Hash) && context["available"] == true &&
          context["weekly_context_fingerprint"].to_s.match?(/\A[0-9a-f]{64}\z/)
        raise Error, (context.is_a?(Hash) ? context["reason"] : nil).presence || "These reported hours require separate historical review"
      end
      regular, overtime = hours!(context["regular_hours"]), hours!(context["overtime_hours"])
      unless (regular + overtime).positive? && hours!(context["total_hours"]) == regular + overtime &&
          hours!(hold["hours"]) == regular + overtime
        raise Error, "Source did not provide complete exact REG and OT hours for this report"
      end
      # Cross-period adjustment items are allowed, scoped to the same company.
      item = PayrollItem.joins(:pay_period).where(pay_periods: { company_id: pay_period.company_id }).find(payroll_item_id)
      client = actor_client
      allocation = PaymentCancellationBridge.with_item_lock(item.id) do
        item.pay_period.with_lock do
          item.with_lock do
            validate_item!(item, source_user_uuid, regular, overtime)
            payment = native_payment!(item)
            intent = hold.slice("source_time_entry_id", "source_time_entry_version", "source_user_uuid", "work_date")
              .merge("command_id" => SecureRandom.uuid, "expected_version" => hold.fetch("version"),
                "regular_hours" => regular.to_s("F"), "overtime_hours" => overtime.to_s("F"),
                "expected_weekly_context_fingerprint" => context.fetch("weekly_context_fingerprint"),
                "external_pay_period_id" => item.pay_period_id.to_s, "external_payroll_item_id" => item.id.to_s,
                "pay_date" => item.pay_period.pay_date.iso8601, "reason" => explanation).merge(payment)
            TimeTrackingManualAllocation.create!(company: pay_period.company, time_tracking_source: source,
              pay_period: item.pay_period, payroll_item: item, employee: item.employee, created_by: actor,
              source_payment_attestation_id: attestation_id.to_s, source_user_uuid: source_user_uuid,
              source_time_entry_id: hold.fetch("source_time_entry_id"), source_time_entry_version: hold.fetch("source_time_entry_version"),
              original_work_date: hold.fetch("work_date"), regular_hours: regular, overtime_hours: overtime,
              reconciliation_note: explanation, payment_resolution_intent: intent.merge(
                "source_instance_id" => source.expected_source_instance_id, "source_contract" => source_contract,
                "actor_binding" => client.payroll_command_binding, "attested_at" => hold.fetch("attested_at"),
                "original_report" => hold.slice("reason", "attested_at", "hours"), "review_pay_period_id" => pay_period.id.to_s))
          end
        end
      end
      sync!(allocation)
      allocation
    rescue ActiveRecord::RecordNotFound
      raise Error, "Choose an existing payroll item for this company"
    end

    def sync!(allocation, raise_on_failure: false)
      authorize!
      PaymentCancellationBridge.with_item_lock(allocation.payroll_item_id) do
        allocation.reload
        return allocation unless allocation.payment_resolution_pending?
        unless allocation.time_tracking_source_id == source.id && allocation.company_id == pay_period.company_id &&
            allocation.created_by_id == actor.id
          raise Client::Error, "Retry this saved match as its original payroll operator and source"
        end
        intent = allocation.payment_resolution_intent
        verify_source!(intent)
        client = Client.for_saved_payroll_actor(source, actor: actor, binding: intent.fetch("actor_binding"))
        # Do not derive a replacement command, tuple or actor after uncertain transport.
        result = client.resolve_payroll_payment_attestation(attestation_id: allocation.source_payment_attestation_id, verified_saved_capability: true,
          **intent.except("source_instance_id", "source_contract", "actor_binding", "attested_at", "original_report", "review_pay_period_id").symbolize_keys)
        remote = acknowledge!(result, allocation)
        allocation.with_lock do
          allocation.update!(status: "issued", remote_allocation_id: remote.fetch("id"), remote_version: remote.fetch("version"),
            payment_resolution_receipt: result, last_sync_error: nil, last_synced_at: Time.current)
        end
      end
      allocation
    rescue Client::Error, ConnectionIdentity::Error, KeyError, TypeError, NoMethodError, ActiveRecord::RecordInvalid => e
      # A failed acknowledgement leaves dirty in-memory attributes. Record only
      # the error on the durable pending row, without replacing any saved tuple
      # or overwriting a concurrent successful reconciliation.
      TimeTrackingManualAllocation.where(id: allocation.id, payment_resolution_receipt: {})
        .where.not(payment_resolution_intent: {}).update_all(last_sync_error: e.message, updated_at: Time.current)
      allocation.reload
      raise Client::Error, e.message if raise_on_failure

      allocation
    end

    def history
      return [] unless source

      source.time_tracking_manual_allocations.where(company_id: pay_period.company_id)
        .resolution_history_for_period(pay_period).where.not(source_payment_attestation_id: nil)
        .includes(:employee, :pay_period).order(:id).map { |allocation| present(allocation) }
    end

    def present(allocation)
      intent = allocation.payment_resolution_intent
      { id: allocation.id, source_payment_attestation_id: allocation.source_payment_attestation_id, verified_saved_capability: true,
        payroll_item_id: allocation.payroll_item_id, pay_period_id: allocation.pay_period_id,
        employee_name: allocation.employee.full_name, original_work_date: allocation.original_work_date.iso8601,
        regular_hours: allocation.regular_hours.to_f, overtime_hours: allocation.overtime_hours.to_f,
        status: allocation.payment_resolution_pending? ? "pending" : "matched", allocation_status: allocation.status,
        payment_method: intent["payment_method"], payment_reference: intent["payment_reference"],
        payment_effective_on: intent["payment_effective_on"], original_report: intent["original_report"], note: allocation.reconciliation_note,
        last_sync_error: allocation.last_sync_error, can_retry: actor.id == allocation.created_by_id,
        hours_reserved: allocation.status != "voided" }
    end

    def payment_options(uuid)
      return [] unless source&.supports?(CAPABILITY)

      mapping = source.time_tracking_employee_mappings.find_by(source_user_uuid: uuid, company_id: pay_period.company_id)
      return [] unless mapping

      PayrollItem.joins(:pay_period).where(pay_periods: { company_id: pay_period.company_id, status: "committed" },
        employee_id: mapping.employee_id, voided: false).order("pay_periods.pay_date DESC", :id).filter_map do |item|
        next if item.time_tracking_entry_allocations.exists? || item.source_accounting_correction_linked? ||
          TimeTrackingClassificationReconciliation.exists?(payroll_item_id: item.id)
        begin
          proof = native_payment!(item)
          reserved = item.time_tracking_manual_allocations.where.not(status: "voided")
          { payroll_item_id: item.id, pay_period_id: item.pay_period_id, pay_date: item.pay_period.pay_date.iso8601,
            gross_pay: item.gross_pay.to_f, net_pay: item.net_pay.to_f,
            regular_hours: item.hours_worked.to_f, overtime_hours: item.overtime_hours.to_f,
            payment_recorded_at: proof.fetch("occurred_at"), regular_hours_available: (item.hours_worked.to_d - reserved.sum(:regular_hours)).to_f,
            overtime_hours_available: (item.overtime_hours.to_d - reserved.sum(:overtime_hours)).to_f,
            payment_method: proof.fetch("payment_method"), payment_reference: proof.fetch("payment_reference"),
            payment_effective_on: proof.fetch("payment_effective_on") }
        rescue ArgumentError, Error
          nil
        end
      end
    end

    private

    attr_reader :pay_period, :source, :actor

    def authorize!
      unless actor && source&.active? && source.company_id == pay_period.company_id &&
          StaffRolePolicy.historical_reconciliation_allowed?(actor, pay_period.company) &&
          TestWorkspaceAccessPolicy.allowed?(user: actor, company: pay_period.company,
            request_method: "POST", capability: :manage_historical_time_reconciliation)
        raise Error, "This operator cannot reconcile reported payments for this company and active source"
      end
    end

    def actor_client
      @actor_client ||= Client.for_payroll_actor(source, actor: actor)
    end

    def reports(uuid)
      unless source.time_tracking_employee_mappings.exists?(source_user_uuid: uuid, company_id: pay_period.company_id)
        raise Error, "Verify the reported employee's permanent source mapping first"
      end
      result = []
      1.upto(10) do |page|
        payload = actor_client.payroll_payment_attestations(source_user_uuid: uuid, page: page,
          start_date: pay_period.start_date.iso8601, end_date: pay_period.end_date.iso8601)
        result.concat(payload.fetch("payment_attestations"))
        return result if page >= Integer(payload.fetch("pagination").fetch("total_pages"))
      end
      raise Error, "Payment report history is too large; ask your administrator to review it"
    end

    def validate_item!(item, uuid, regular, overtime)
      unless source.time_tracking_employee_mappings.exists?(source_user_uuid: uuid, employee_id: item.employee_id, company_id: item.pay_period.company_id)
        raise Error, "Choose an issued payroll item for this exact mapped employee"
      end
      if item.time_tracking_entry_allocations.exists? || item.source_accounting_correction_linked? ||
          TimeTrackingClassificationReconciliation.exists?(payroll_item_id: item.id)
        raise Error, "Use this paycheck's existing source or historical classification reconciliation"
      end
      if item.time_tracking_manual_allocations.pending_payment_resolution.exists? ||
          item.time_tracking_manual_allocations.where.not(payment_cancellation_intent: {}).exists?
        raise Error, "Reconcile the earlier saved payment transition before matching more hours"
      end
      reserved = item.time_tracking_manual_allocations.where.not(status: "voided")
      if reserved.sum(:regular_hours).to_d + regular > item.hours_worked.to_d.round(2) ||
          reserved.sum(:overtime_hours).to_d + overtime > item.overtime_hours.to_d.round(2)
        raise Error, "This existing paycheck cannot cover the complete separate REG and OT hours"
      end
    end

    def native_payment!(item)
      proof = OriginalPaymentProof.call(item)
      if proof.fetch(:method) == "direct_deposit"
        event = item.direct_deposit_payment_confirmation
        { "payment_method" => "direct_deposit", "payment_reference" => event.bank_reference,
          "payment_effective_on" => event.settled_on.iso8601, "occurred_at" => event.created_at.iso8601(6),
          "payroll_payment_event_type" => "direct_deposit_confirmation", "payroll_payment_event_id" => event.id.to_s }
      else
        event = item.check_events.deliveries.where(check_number: item.check_number).order(:created_at, :id).last!
        { "payment_method" => "paper_check", "payment_reference" => item.check_number,
          "payment_effective_on" => event.effective_on.iso8601, "occurred_at" => event.created_at.iso8601(6),
          "payroll_payment_event_type" => "delivered_check", "payroll_payment_event_id" => event.id.to_s }
      end
    end

    def source_contract
      { "protocol" => source.source_protocol, "protocol_version" => source.source_protocol_version,
        "capabilities" => source.source_capabilities.sort, "policy_constraints" => source.source_policy_constraints,
        "source_identifier" => source.connector.source_identifier }
    end

    def verify_source!(intent)
      source.reload
      contract = intent["source_contract"]
      unless source.remote_identity_pinned? && source.expected_source_instance_id == intent["source_instance_id"] &&
          contract.is_a?(Hash) && contract["protocol"] == ConnectionIdentity::PROTOCOL &&
          ConnectionIdentity::SUPPORTED_PROTOCOL_VERSIONS.include?(contract["protocol_version"]) &&
          Array(contract["capabilities"]).include?(CAPABILITY) &&
          contract["source_identifier"] == source.connector.source_identifier
        raise Client::Error, "The saved match requires its original verified source installation and contract"
      end
    end

    def acknowledge!(result, allocation)
      raise Client::Error, RECEIPT_ERROR unless result.is_a?(Hash)

      intent = allocation.payment_resolution_intent
      identity = ConnectionIdentity.validate!(source: source, payload: result)
      contract = intent.fetch("source_contract")
      command, receipt, report, remote = result.values_at("command", "command_result", "payment_attestation", "manual_allocation")
      valid = !identity.legacy && identity.source_instance_id == intent["source_instance_id"] &&
        identity.protocol == contract["protocol"] && identity.protocol_version == contract["protocol_version"] &&
        identity.capabilities == contract["capabilities"] && identity.policy_constraints == contract["policy_constraints"] &&
        identity.source_identifier == contract["source_identifier"] && command.is_a?(Hash) &&
        command["id"] == intent["command_id"] && [ true, false ].include?(command["replayed"]) &&
        receipt.is_a?(Hash) && report.is_a?(Hash) && remote.is_a?(Hash) &&
        receipt["payment_attestation"] == report && receipt["manual_allocation"] == remote &&
        receipt["integration"] == result["integration"] && valid_report?(report, receipt, remote, allocation, intent) &&
        valid_allocation?(remote, receipt, intent)
      raise Client::Error, RECEIPT_ERROR unless valid

      remote
    rescue ArgumentError, TypeError, KeyError, Error
      raise Client::Error, RECEIPT_ERROR
    end

    def valid_report?(report, receipt, remote, allocation, intent)
      return false unless report["id"] == allocation.source_payment_attestation_id &&
        receipt["payment_attestation_id"].to_s == report["id"] && receipt["status"] == "resolved" && report["status"] == "resolved" &&
        receipt["expected_version"] == intent["expected_version"] && advancing?(receipt["expected_version"], receipt["result_version"]) &&
        receipt["result_version"] == report["version"] && report["attested_at"] == intent["attested_at"] &&
        report["resolved_by_id"].is_a?(String) && report["resolved_by_id"].present? &&
        valid_time?(report["resolved_at"]) && Time.iso8601(report["resolved_at"]) >= Time.iso8601(report["attested_at"]) &&
        report["resolved_manual_allocation_id"] == remote["id"] &&
        report["resolved_issued_event_id"] == remote.dig("issued_payment", "event_id") &&
        hours!(report["hours"]) == allocation.total_hours
      return false unless %w[source_time_entry_id source_time_entry_version source_user_uuid work_date].all? { |key| report[key] == intent[key] }

      expected = intent.slice("expected_weekly_context_fingerprint", "payroll_payment_event_type", "payroll_payment_event_id")
      report["resolution_evidence"] == expected && expected.all? { |key, value| receipt[key] == value }
    end

    def valid_allocation?(remote, receipt, intent)
      return false unless remote["id"].is_a?(String) && remote["id"].match?(/\A[1-9]\d*\z/) &&
        receipt["manual_allocation_id"].to_s == remote["id"] && remote["status"] == "issued" &&
        advancing?(receipt["manual_allocation_expected_version"], receipt["manual_allocation_result_version"]) &&
        receipt["manual_allocation_result_version"] == remote["version"] &&
        %w[source_time_entry_id source_time_entry_version source_user_uuid work_date pay_date external_pay_period_id external_payroll_item_id
          payment_method payment_reference payment_effective_on].all? { |key| remote[key] == intent[key] } &&
        hours!(remote["regular_hours"]) == hours!(intent["regular_hours"]) && hours!(remote["overtime_hours"]) == hours!(intent["overtime_hours"]) &&
        hours!(remote["total_hours"]) == hours!(intent["regular_hours"]) + hours!(intent["overtime_hours"])
      payment = remote["issued_payment"]
      payment.is_a?(Hash) && payment["event_id"].is_a?(String) && payment["event_id"].present? && payment["event_type"] == "issued" &&
        %w[payment_method payment_reference payment_effective_on].all? { |key| payment[key] == intent[key] } &&
        [ remote["issued_at"], payment["occurred_at"] ].all? { |value| valid_time?(value) && Time.iso8601(value) == Time.iso8601(intent["occurred_at"]) }
    end

    def advancing?(before, after)
      before.is_a?(Integer) && before >= 0 && after.is_a?(Integer) && after > before
    end

    def valid_time?(value)
      value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/) && Time.iso8601(value)
    end

    def hours!(value)
      raise Error, "Source hours must be finite, non-negative and exact to two decimals" unless value.is_a?(String) || value.is_a?(Numeric)
      amount = BigDecimal(value.to_s)
      raise Error, "Source hours must be finite, non-negative and exact to two decimals" unless amount.finite? && amount >= 0 && amount.round(2) == amount

      amount
    rescue ArgumentError
      raise Error, "Source hours must be numeric"
    end

    def in_period?(value)
      (pay_period.start_date..pay_period.end_date).cover?(Date.iso8601(value.to_s))
    rescue ArgumentError
      false
    end
  end
end
