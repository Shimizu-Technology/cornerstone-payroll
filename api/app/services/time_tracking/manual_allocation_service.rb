# frozen_string_literal: true

module TimeTracking
  class ManualAllocationService
    class Error < StandardError; end

    def initialize(pay_period:, source:, actor:)
      @pay_period = pay_period
      @source = source
      @actor = actor
    end

    def create!(payroll_item_id:, source_time_entry_id:, source_time_entry_version:,
                source_user_uuid:, regular_hours:, overtime_hours:, original_work_date:, note:,
                classification_reconciliation: nil)
      raise Error, "Commit the payroll before linking paid hours" unless pay_period.committed? && !pay_period.voided?
      raise Error, "Connect an active time-tracking source first" unless source&.active? && source.company_id == pay_period.company_id

      raise Error, "This source does not support manual payroll allocations" unless source.supports?(:manual_allocations)

      item = pay_period.payroll_items.find(payroll_item_id)
      raise Error, "A voided paycheck cannot pay these hours" if item.voided?
      raise Error, "Use the finalized source batch reconciliation for this paycheck" if item.time_tracking_entry_allocations.exists?

      uuid = TimeTrackingEmployeeMapping.normalize_uuid(source_user_uuid)
      mapping = source.time_tracking_employee_mappings.find_by(source_user_uuid: uuid, employee_id: item.employee_id)
      raise Error, "Map this source employee to the payroll employee before linking hours" unless mapping

      entry_id = source_time_entry_id.to_s
      version = begin
        Integer(source_time_entry_version.to_s, 10)
      rescue ArgumentError
        raise Error, "Refresh the source and choose a valid dated time entry with exact hours"
      end
      raise Error, "Refresh the source time entry before linking it" if version.negative?
      regular = decimal_hours!(regular_hours)
      overtime = decimal_hours!(overtime_hours)
      raise Error, "Choose at least some hours" unless (regular + overtime).positive?
      work_date = begin
        Date.iso8601(original_work_date.to_s)
      rescue Date::Error
        raise Error, "Refresh the source and choose a valid dated time entry with exact hours"
      end
      explanation = note.to_s.strip
      raise Error, "Explain which issued or committed payroll item covers these hours" if explanation.length < 10
      validate_classification_reconciliation!(classification_reconciliation, item, entry_id, uuid, version, work_date, regular, overtime) if classification_reconciliation
      if !classification_reconciliation && TimeTrackingClassificationReconciliation.exists?(payroll_item_id: item.id)
        raise Error, "Finish the reviewed historical classification reconciliation for this paycheck"
      end

      begin
        verify_live_source!(entry_id, uuid, version, work_date, regular, overtime)
      rescue Error
        existing = TimeTrackingManualAllocation.find_by(time_tracking_source: source,
          source_time_entry_id: entry_id, payroll_item_id: item.id)
        if matching_classification_allocation?(existing, classification_reconciliation, uuid, version, work_date, regular, overtime)
          sync!(existing)
          return existing
        end
        raise
      end

      allocation = item.with_lock do
        raise Error, "A voided paycheck cannot pay these hours" if item.voided?
        unless item.effective_payment_delivery_method.in?(%w[paper_check direct_deposit])
          raise Error, "Choose a supported payroll payment method before linking hours"
        end
        raise Error, "Use the finalized source batch reconciliation for this paycheck" if item.time_tracking_entry_allocations.exists?
        if !classification_reconciliation && TimeTrackingClassificationReconciliation.exists?(payroll_item_id: item.id)
          raise Error, "Finish the reviewed historical classification reconciliation for this paycheck"
        end
        existing = TimeTrackingManualAllocation.find_by(time_tracking_source: source,
          source_time_entry_id: entry_id, payroll_item_id: item.id)
        if existing
          if matching_classification_allocation?(existing, classification_reconciliation, uuid, version, work_date, regular, overtime)
            next existing
          end
          raise Error, "This source time entry is already linked to this payroll item"
        end
        allocated = item.pay_period.time_tracking_manual_allocations.where(payroll_item_id: item.id).where.not(status: "voided")
        if classification_reconciliation
          if allocated.sum(:regular_hours).to_d + allocated.sum(:overtime_hours).to_d + regular + overtime >
             item.hours_worked.to_d.round(2) + item.overtime_hours.to_d.round(2)
            raise Error, "Selected hours exceed the total hours on this issued paycheck"
          end
        elsif allocated.sum(:regular_hours).to_d + regular > item.hours_worked.to_d.round(2) ||
              allocated.sum(:overtime_hours).to_d + overtime > item.overtime_hours.to_d.round(2)
          raise Error, "Selected hours exceed the regular or overtime hours on this paycheck"
        end

        TimeTrackingManualAllocation.create!(
          company: pay_period.company,
          time_tracking_source: source,
          pay_period: pay_period,
          payroll_item: item,
          employee: item.employee,
          created_by: actor,
          source_user_uuid: uuid,
          source_time_entry_id: entry_id,
          source_time_entry_version: version,
          original_work_date: work_date,
          regular_hours: regular,
          overtime_hours: overtime,
          reconciliation_note: explanation,
          classification_reconciliation: classification_reconciliation
        )
      end

      sync!(allocation)
      allocation
    rescue ActiveRecord::RecordNotFound
      raise Error, "This payroll item was not found in the selected pay period"
    end

    def sync!(allocation, raise_on_failure: false)
      PaymentCancellationBridge.with_item_lock(allocation.payroll_item_id) do
        validate_sync_source!(allocation.reload)
        if allocation.payment_resolution_pending?
          begin
            PaymentAttestationResolutionService.new(pay_period: pay_period, source: source, actor: actor).sync!(allocation, raise_on_failure: true)
          rescue PaymentAttestationResolutionService::Error => e
            raise TimeTracking::Client::Error.new(e.message, response_status: 422)
          end
          return allocation
        end
        4.times do
          allocation.reload
          transitioned = if allocation.payment_cancellation_intent.present? && allocation.status != "pending_commit"
            sync_cancellation!(allocation)
          else
            case allocation.status
            when "pending_commit" then sync_commit!(allocation)
            when "committed" then sync_committed!(allocation)
            when "issued" then sync_issued!(allocation)
            else false
            end
          end
          break unless transitioned
        end
      end
      allocation
    rescue TimeTracking::Client::Error => e
      allocation.with_lock { allocation.update!(last_sync_error: e.message) }
      raise if raise_on_failure

      allocation
    end

    private

    attr_reader :pay_period, :source, :actor

    def matching_classification_allocation?(allocation, reconciliation, uuid, version, work_date, regular, overtime)
      allocation && reconciliation && allocation.classification_reconciliation_id == reconciliation.id &&
        allocation.status != "voided" && allocation.source_user_uuid == uuid &&
        allocation.source_time_entry_version == version && allocation.original_work_date == work_date &&
        allocation.regular_hours == regular && allocation.overtime_hours == overtime
    end

    def validate_classification_reconciliation!(reconciliation, item, entry_id, uuid, version, work_date, regular, overtime)
      unless reconciliation.is_a?(TimeTrackingClassificationReconciliation) &&
             reconciliation.persisted? && reconciliation.status == "pending" &&
             reconciliation.pay_period_id == pay_period.id && reconciliation.payroll_item_id == item.id &&
             reconciliation.time_tracking_source_id == source.id && reconciliation.employee_id == item.employee_id &&
             reconciliation.source_user_uuid == uuid
        raise Error, "Historical classification review does not match this source employee and issued check"
      end
      snapshot = Array(reconciliation.source_entries).find { |row| row["source_time_entry_id"].to_s == entry_id }
      unless snapshot && snapshot["source_time_entry_version"].is_a?(Integer) && snapshot["source_time_entry_version"] == version &&
             snapshot["original_work_date"] == work_date.iso8601 &&
             BigDecimal(snapshot["regular_hours"].to_s) == regular &&
             BigDecimal(snapshot["overtime_hours"].to_s) == overtime
        raise Error, "This source entry is not in the reviewed historical classification exception"
      end
      delivery = delivered_check_event_for(item)
      unless item.effective_payment_delivery_method == "paper_check" && item.check_number == reconciliation.check_number &&
             delivery&.effective_on == reconciliation.payment_effective_on && item.net_pay.to_d.positive? &&
             item.hours_worked.to_d.round(2) == reconciliation.payroll_regular_hours &&
             item.overtime_hours.to_d.round(2) == reconciliation.payroll_overtime_hours
        raise Error, "Issued-check evidence changed; review the historical classification exception again"
      end
    rescue ArgumentError
      raise Error, "Historical classification snapshot is invalid"
    end

    def sync_commit!(allocation)
      result = client_for(allocation).commit_payroll_manual_allocation(
        entry_id: allocation.source_time_entry_id,
        command_id: allocation.commit_command_id,
        expected_version: allocation.source_time_entry_version,
        source_user_uuid: allocation.source_user_uuid,
        regular_hours: allocation.regular_hours.to_s("F"),
        overtime_hours: allocation.overtime_hours.to_s("F"),
        external_pay_period_id: allocation.pay_period_id.to_s,
        external_payroll_item_id: allocation.payroll_item_id.to_s,
        pay_date: allocation.pay_period.pay_date.iso8601,
        reason: allocation.reconciliation_note
      )
      remote = remote_allocation_acknowledgement!(result)
      allocation.with_lock do
        next unless allocation.status == "pending_commit"

        allocation.update!(status: "committed", remote_allocation_id: remote.fetch("id"),
                           remote_version: remote.fetch("version"), last_sync_error: nil,
                           last_synced_at: Time.current)
      end
      true
    end

    def sync_committed!(allocation)
      item = allocation.payroll_item.reload
      if !item.voided? && item.effective_payment_delivery_method == "direct_deposit" &&
         (confirmation = item.direct_deposit_payment_confirmation)
        result = issue_with_durable_intent!(allocation,
          allocation_id: allocation.remote_allocation_id,
          command_id: allocation.issue_command_id,
          expected_version: allocation.remote_version,
          payment_method: "direct_deposit",
          payment_reference: confirmation.bank_reference,
          payment_effective_on: confirmation.settled_on.iso8601,
          occurred_at: confirmation.created_at.iso8601(6),
          reason: "Cornerstone bank payment #{confirmation.bank_reference} confirmed for #{confirmation.settled_on.iso8601}"
        )
        persist_remote_transition!(allocation, "committed", "issued", result)
        return true
      end
      if !item.voided? && (delivery = delivered_check_event(allocation))
        result = issue_with_durable_intent!(allocation,
          allocation_id: allocation.remote_allocation_id,
          command_id: allocation.issue_command_id,
          expected_version: allocation.remote_version,
          payment_method: "paper_check",
          payment_reference: item.check_number,
          payment_effective_on: delivery.effective_on.iso8601,
          occurred_at: delivery.created_at.iso8601(6),
          reason: "Cornerstone check #{item.check_number} delivered on #{delivery.effective_on.iso8601}"
        )
        persist_remote_transition!(allocation, "committed", "issued", result)
        return true
      end
      return false if item.payroll_included?

      result = client_for(allocation).void_payroll_manual_allocation(
        allocation_id: allocation.remote_allocation_id,
        command_id: allocation.void_command_id,
        expected_version: allocation.remote_version,
        occurred_at: (item.payroll_reversed_at || item.pay_period.voided_at || item.voided_at).iso8601(6),
        reason: "Cornerstone payroll item #{allocation.payroll_item_id} was voided"
      )
      persist_remote_transition!(allocation, "committed", "voided", result)
      true
    end

    def issue_with_durable_intent!(allocation, **payload)
      allocation.with_lock do
        if allocation.payment_issue_intent.blank?
          original_source = allocation.time_tracking_source.reload
          unless original_source.remote_identity_pinned?
            raise TimeTracking::Client::Error, "Verify the original source installation before issuing manual payroll hours"
          end
          allocation.update!(payment_issue_intent: payload.stringify_keys.merge(
            "source_instance_id" => original_source.expected_source_instance_id,
            "source_contract" => {
              "protocol" => original_source.source_protocol,
              "protocol_version" => original_source.source_protocol_version,
              "capabilities" => original_source.source_capabilities.sort,
              "policy_constraints" => original_source.source_policy_constraints
            }))
        end
      end
      # Reuse the saved original command and tuple after an uncertain response.
      intent = allocation.reload.payment_issue_intent
      issue_saved_intent!(allocation, intent)
    end

    def issue_saved_intent!(allocation, intent)
      # The client reloads the source. Check the saved pin after that reload so
      # a reconfigured installation cannot receive the original command.
      client = client_for(allocation)
      verify_issue_source!(allocation, intent)
      client.issue_payroll_manual_allocation(**intent.except("source_instance_id", "source_contract").symbolize_keys)
    end

    def sync_cancellation!(allocation)
      intent = allocation.payment_cancellation_intent
      unless allocation.time_tracking_source.supports?(:payment_cancellation_v1)
        raise TimeTracking::Client::Error, "The original source has not verified payment cancellation support"
      end
      # A remote issue may have succeeded before its local status write failed.
      # Replay that exact durable command, then cancel its acknowledged version.
      if allocation.payment_issue_intent.present? && !intent.key?("expected_version")
        result = issue_saved_intent!(allocation, allocation.payment_issue_intent)
        remote = issued_allocation_acknowledgement!(result, allocation)
        allocation.with_lock { allocation.update!(remote_version: remote.fetch("version")) }
      end
      unless intent.key?("expected_version")
        allocation.with_lock do
          # Version is frozen before the HTTP request, so a lost response can
          # replay the same immutable command without deriving new arguments.
          intent = allocation.payment_cancellation_intent.merge("expected_version" => allocation.remote_version)
          allocation.update!(payment_cancellation_intent: intent)
        end
      end
      payload = intent.except("check_event_id").symbolize_keys.merge(allocation_id: allocation.remote_allocation_id)
      result = client_for(allocation).cancel_payroll_manual_allocation_payment(**payload)
      remote = remote_allocation_acknowledgement!(result, expected_id: allocation.remote_allocation_id)
      unless valid_cancellation_acknowledgement?(result, allocation, intent, remote)
        raise TimeTracking::Client::Error, "The source did not acknowledge the committed payroll obligation after cancellation"
      end
      persist_cancellation_acknowledgement!(allocation, intent, remote)
      true
    end

    def valid_cancellation_acknowledgement?(result, allocation, intent, remote)
      command = result["command"]
      return false unless command.is_a?(Hash) && command["id"] == intent["command_id"] &&
        remote["status"] == "committed" && remote.fetch("version") > intent.fetch("expected_version")

      expected = {
        "source_time_entry_id" => allocation.source_time_entry_id,
        "source_time_entry_version" => allocation.source_time_entry_version,
        "source_user_uuid" => allocation.source_user_uuid,
        "work_date" => allocation.original_work_date.iso8601,
        "external_pay_period_id" => allocation.pay_period_id.to_s,
        "external_payroll_item_id" => allocation.payroll_item_id.to_s
      }
      return false unless expected.all? { |key, value| remote[key] == value }
      return false unless cancellation_hours_match?(remote["regular_hours"], allocation.regular_hours) &&
        cancellation_hours_match?(remote["overtime_hours"], allocation.overtime_hours)

      payment = remote["cancelled_payment"]
      return false unless payment.is_a?(Hash) && (payment["event_id"].is_a?(String) || payment["event_id"].is_a?(Integer)) && payment["event_id"].to_s.present? &&
        payment["event_type"] == "payment_cancelled" &&
        %w[payment_method payment_reference payment_effective_on cancellation_evidence_reference reason].all? { |key| payment[key] == intent[key] }

      payment["occurred_at"].is_a?(String) && Time.iso8601(payment["occurred_at"]) == Time.iso8601(intent.fetch("occurred_at"))
    rescue ArgumentError, TypeError
      false
    end

    def cancellation_hours_match?(actual, expected)
      return false unless actual.is_a?(String) || actual.is_a?(Numeric)

      amount = BigDecimal(actual.to_s)
      amount.finite? && amount == expected.to_d
    rescue ArgumentError, TypeError
      false
    end

    def persist_cancellation_acknowledgement!(allocation, intent, remote)
      allocation.with_lock do
        next unless allocation.payment_cancellation_intent["command_id"] == intent["command_id"]

        allocation.update!(status: "committed", remote_version: remote.fetch("version"),
          payment_cancellation_receipts: allocation.payment_cancellation_receipts + [ intent.merge(
            "acknowledged_at" => Time.current.iso8601(6), "remote_version" => remote.fetch("version"),
            "source_instance_id" => allocation.time_tracking_source.expected_source_instance_id,
            "source_acknowledgement" => remote.slice("id", "version", "status", "source_time_entry_id",
              "source_time_entry_version", "source_user_uuid", "work_date", "regular_hours", "overtime_hours",
              "external_pay_period_id", "external_payroll_item_id", "cancelled_payment")) ],
          payment_cancellation_intent: {}, payment_issue_intent: {},
          issue_command_id: SecureRandom.uuid, last_sync_error: nil, last_synced_at: Time.current)
      end
    end

    def sync_issued!(allocation)
      return false unless allocation.payroll_item.reload.voided?

      # A delivered check may still be cashed after a software void. Keep
      # the source's paid claim until nonpayment/replacement evidence is reviewed.
      allocation.with_lock do
        if allocation.status == "issued"
          allocation.update!(
            last_sync_error: "Delivered check was voided in Cornerstone. Verify bank nonpayment or replacement before releasing these hours."
          )
        end
      end
      false
    end

    def persist_remote_transition!(allocation, from, to, result)
      remote = to == "issued" ? issued_allocation_acknowledgement!(result, allocation) :
        remote_allocation_acknowledgement!(result, expected_id: allocation.remote_allocation_id)
      allocation.with_lock do
        next unless allocation.status == from

        allocation.update!(payment_issue_intent: {}, status: to, remote_version: remote.fetch("version"),
                           last_sync_error: nil, last_synced_at: Time.current)
      end
    end

    def verify_issue_source!(allocation, intent)
      original_source = allocation.time_tracking_source.reload
      contract = intent["source_contract"]
      unless original_source.remote_identity_pinned? && intent["source_instance_id"].present? &&
        intent["source_instance_id"] == original_source.expected_source_instance_id && contract.is_a?(Hash) &&
        contract["protocol"] == ConnectionIdentity::PROTOCOL &&
        ConnectionIdentity::SUPPORTED_PROTOCOL_VERSIONS.include?(contract["protocol_version"]) &&
        contract["capabilities"].is_a?(Array) && contract["capabilities"].include?("manual_allocations") &&
        contract["policy_constraints"].is_a?(Hash)
        raise TimeTracking::Client::Error, "The saved manual payment needs its original verified source installation; review the source before retrying"
      end
    end

    def issued_allocation_acknowledgement!(result, allocation)
      remote = remote_allocation_acknowledgement!(result, expected_id: allocation.remote_allocation_id)
      intent = allocation.payment_issue_intent
      verify_issue_source!(allocation, intent)
      identity = ConnectionIdentity.validate!(source: allocation.time_tracking_source, payload: result)
      contract = intent["source_contract"]
      unless !identity.legacy && identity.source_instance_id == intent["source_instance_id"] &&
        contract.is_a?(Hash) && identity.protocol == contract["protocol"] && identity.protocol_version == contract["protocol_version"] &&
        identity.capabilities.include?("manual_allocations") && identity.capabilities == contract["capabilities"] &&
        identity.policy_constraints == contract["policy_constraints"] &&
        valid_issued_allocation?(result, remote, allocation, intent)
        raise TimeTracking::Client::Error, "The source did not prove this exact issued manual payment; update the source receipt support and retry the saved sync"
      end

      remote
    rescue ConnectionIdentity::Error => e
      raise TimeTracking::Client::Error, e.message
    end

    def valid_issued_allocation?(result, remote, allocation, intent)
      command = result["command"]
      return false unless command.is_a?(Hash) && command["id"] == intent["command_id"] &&
        [ true, false ].include?(command["replayed"]) && intent["command_id"] == allocation.issue_command_id &&
        intent["allocation_id"].to_s == allocation.remote_allocation_id.to_s && remote["status"] == "issued" &&
        intent["expected_version"].is_a?(Integer) && remote["version"] > intent["expected_version"] &&
        valid_issued_command_result?(result, remote, intent)

      expected = {
        "source_time_entry_id" => allocation.source_time_entry_id,
        "source_time_entry_version" => allocation.source_time_entry_version,
        "source_user_uuid" => allocation.source_user_uuid,
        "work_date" => allocation.original_work_date.iso8601,
        "pay_date" => allocation.pay_period.pay_date.iso8601,
        "external_pay_period_id" => allocation.pay_period_id.to_s,
        "external_payroll_item_id" => allocation.payroll_item_id.to_s
      }
      return false unless expected.all? { |key, value| remote[key] == value }
      return false unless cancellation_hours_match?(remote["regular_hours"], allocation.regular_hours) &&
        cancellation_hours_match?(remote["overtime_hours"], allocation.overtime_hours) &&
        cancellation_hours_match?(remote["total_hours"], allocation.total_hours)

      payment = remote["issued_payment"]
      return false unless payment.is_a?(Hash) && valid_issue_event_id?(payment["event_id"]) && payment["event_type"] == "issued"
      return false unless %w[payment_method payment_reference payment_effective_on].all? do |key|
        remote[key] == intent[key] && payment[key] == intent[key]
      end

      [ remote["issued_at"], payment["occurred_at"] ].all? do |time|
        time.is_a?(String) && Time.iso8601(time) == Time.iso8601(intent.fetch("occurred_at"))
      end
    rescue ArgumentError, TypeError, KeyError
      false
    end

    def valid_issue_event_id?(value)
      (value.is_a?(String) && value.present?) || (value.is_a?(Integer) && value.positive?)
    end

    def valid_issued_command_result?(result, remote, intent)
      receipt = result["command_result"]
      return false unless receipt.is_a?(Hash) && receipt["expected_version"].is_a?(Integer) &&
        receipt["result_version"].is_a?(Integer) && receipt["expected_version"] == intent["expected_version"] &&
        receipt["result_version"] == remote["version"] && receipt["status"] == "issued" &&
        receipt["manual_allocation_id"].to_s == remote["id"].to_s && receipt["integration"] == result["integration"]

      snapshot = receipt["manual_allocation"]
      return false unless snapshot.is_a?(Hash) && snapshot["issued_payment"].is_a?(Hash) && remote["issued_payment"].is_a?(Hash)

      fields = %w[id version source_time_entry_id source_time_entry_version source_user_uuid work_date pay_date
        time_category_id regular_hours overtime_hours total_hours external_pay_period_id external_payroll_item_id
        status payment_method payment_reference payment_effective_on issued_at]
      fields.all? { |key| snapshot[key] == remote[key] } &&
        snapshot["issued_payment"].except("reason") == remote["issued_payment"].except("reason")
    end

    def remote_allocation_acknowledgement!(result, expected_id: nil)
      remote = result.is_a?(Hash) ? result["manual_allocation"] : nil
      id = remote.is_a?(Hash) ? remote["id"].to_s : ""
      version = remote.is_a?(Hash) ? remote["version"] : nil
      valid_version = version.is_a?(Integer) && version >= 0
      unless id.match?(/\A[1-9]\d*\z/) && valid_version && (expected_id.nil? || id == expected_id.to_s)
        raise TimeTracking::Client::Error, "The source returned an invalid manual allocation acknowledgement; retry the sync"
      end

      remote
    end

    def verify_live_source!(entry_id, uuid, version, work_date, regular, overtime)
      review = client_for_source.payroll_cockpit_manual_review(
        start_date: pay_period.start_date.iso8601,
        end_date: pay_period.end_date.iso8601,
        external_pay_period_id: pay_period.id
      )
      row = Array(review["employees"]).find { |employee| employee["source_user_uuid"].to_s.downcase == uuid }
      adjustment = Array(row&.fetch("adjustments", [])).find { |candidate| candidate["source_time_entry_id"].to_s == entry_id }
      unless adjustment && adjustment["source_time_entry_version"].is_a?(Integer) && adjustment["source_time_entry_version"] == version &&
             adjustment["original_work_date"] == work_date.iso8601 &&
             regular <= BigDecimal(adjustment["regular_hours"].to_s) &&
             overtime <= BigDecimal(adjustment["overtime_hours"].to_s)
        raise Error, "The source no longer shows these exact unpaid hours. Refresh the manual hours check."
      end
    end

    def validate_sync_source!(allocation)
      original_source = allocation.time_tracking_source.reload
      return if original_source.active? && original_source.company_id == allocation.company_id &&
        allocation.company_id == pay_period.company_id && allocation.pay_period_id == pay_period.id &&
        source&.id == original_source.id && source.company_id == allocation.company_id

      raise TimeTracking::Client::Error.new(
        "The manual allocation's original time-tracking source is inactive or does not match this payroll. Review the source before retrying.",
        response_status: 422
      )
    end

    def client_for(allocation)
      validate_sync_source!(allocation)
      @clients_by_source ||= {}
      @clients_by_source[allocation.time_tracking_source_id] ||= TimeTracking::Client.for_payroll_actor(
        allocation.time_tracking_source, actor: actor
      )
    end

    def client_for_source
      @client_for_source ||= TimeTracking::Client.for_payroll_actor(source, actor: actor)
    end

    def delivered_check_event(allocation)
      item = allocation.payroll_item
      return unless item.effective_payment_delivery_method == "paper_check" && item.check_number.present?

      item.check_events.deliveries.where(check_number: item.check_number).order(:id).last
    end

    def delivered_check_event_for(item)
      return unless item.check_number.present?

      item.check_events.deliveries.where(check_number: item.check_number).order(:id).last
    end

    def decimal_hours!(value)
      raw = BigDecimal(value.to_s)
      raise Error, "Hours must be non-negative with at most two decimals" unless raw.finite? && !raw.negative? && raw.round(2) == raw

      raw
    rescue ArgumentError
      raise Error, "Hours must be numeric"
    end
  end
end
