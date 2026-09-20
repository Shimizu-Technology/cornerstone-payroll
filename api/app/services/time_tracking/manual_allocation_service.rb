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
                source_user_uuid:, regular_hours:, overtime_hours:, original_work_date:, note:)
      raise Error, "Commit the payroll before linking paid AIRE hours" unless pay_period.committed? && !pay_period.voided?
      raise Error, "Connect an active AIRE source first" unless source&.active? && source.company_id == pay_period.company_id

      item = pay_period.payroll_items.find(payroll_item_id)
      raise Error, "A voided paycheck cannot pay AIRE hours" if item.voided?
      raise Error, "Use the finalized AIRE batch reconciliation for this paycheck" if item.time_tracking_entry_allocations.exists?

      uuid = TimeTrackingEmployeeMapping.normalize_uuid(source_user_uuid)
      mapping = source.time_tracking_employee_mappings.find_by(source_user_uuid: uuid, employee_id: item.employee_id)
      raise Error, "Map this AIRE person to the payroll employee before linking hours" unless mapping

      entry_id = source_time_entry_id.to_s
      version = begin
        Integer(source_time_entry_version.to_s, 10)
      rescue ArgumentError
        raise Error, "Refresh AIRE and choose a valid dated time entry with exact hours"
      end
      raise Error, "Refresh the AIRE time entry before linking it" if version.negative?
      regular = decimal_hours!(regular_hours)
      overtime = decimal_hours!(overtime_hours)
      raise Error, "Choose at least some AIRE hours" unless (regular + overtime).positive?
      work_date = begin
        Date.iso8601(original_work_date.to_s)
      rescue Date::Error
        raise Error, "Refresh AIRE and choose a valid dated time entry with exact hours"
      end
      explanation = note.to_s.strip
      raise Error, "Explain which issued or committed payroll item covers these AIRE hours" if explanation.length < 10

      verify_live_source!(entry_id, uuid, version, work_date, regular, overtime)

      allocation = nil
      item.with_lock do
        raise Error, "A voided paycheck cannot pay AIRE hours" if item.voided?
        unless item.effective_payment_delivery_method.in?(%w[paper_check direct_deposit])
          raise Error, "Choose a supported payroll payment method before linking AIRE hours"
        end
        raise Error, "Use the finalized AIRE batch reconciliation for this paycheck" if item.time_tracking_entry_allocations.exists?
        if TimeTrackingManualAllocation.where(time_tracking_source: source, source_time_entry_id: entry_id,
                                              payroll_item_id: item.id).exists?
          raise Error, "This AIRE time entry is already linked to this payroll item"
        end
        allocated = item.pay_period.time_tracking_manual_allocations.where(payroll_item_id: item.id).where.not(status: "voided")
        if allocated.sum(:regular_hours).to_d + regular > item.hours_worked.to_d.round(2) ||
           allocated.sum(:overtime_hours).to_d + overtime > item.overtime_hours.to_d.round(2)
          raise Error, "Selected AIRE hours exceed the regular or overtime hours on this paycheck"
        end

        allocation = TimeTrackingManualAllocation.create!(
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
          reconciliation_note: explanation
        )
      end

      sync!(allocation)
      allocation
    rescue ActiveRecord::RecordNotFound
      raise Error, "This payroll item was not found in the selected pay period"
    end

    def sync!(allocation, raise_on_failure: false)
      3.times do
        allocation.reload
        transitioned = case allocation.status
        when "pending_commit" then sync_commit!(allocation)
        when "committed" then sync_committed!(allocation)
        when "issued" then sync_issued!(allocation)
        else false
        end
        break unless transitioned
      end
      allocation
    rescue TimeTracking::Client::Error => e
      allocation.with_lock { allocation.update!(last_sync_error: e.message) }
      raise if raise_on_failure

      allocation
    end

    private

    attr_reader :pay_period, :source, :actor

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
        result = client_for(allocation).issue_payroll_manual_allocation(
          allocation_id: allocation.remote_allocation_id,
          command_id: allocation.issue_command_id,
          expected_version: allocation.remote_version,
          payment_method: "direct_deposit",
          payment_reference: confirmation.bank_reference,
          occurred_at: confirmation.created_at.iso8601,
          reason: "Cornerstone bank payment #{confirmation.bank_reference} confirmed for #{confirmation.settled_on.iso8601}"
        )
        persist_remote_transition!(allocation, "committed", "issued", result)
        return true
      end
      if !item.voided? && (delivery = delivered_check_event(allocation))
        result = client_for(allocation).issue_payroll_manual_allocation(
          allocation_id: allocation.remote_allocation_id,
          command_id: allocation.issue_command_id,
          expected_version: allocation.remote_version,
          payment_method: "paper_check",
          payment_reference: item.check_number,
          occurred_at: delivery.created_at.iso8601,
          reason: "Cornerstone check #{item.check_number} delivered on #{delivery.effective_on.iso8601}"
        )
        persist_remote_transition!(allocation, "committed", "issued", result)
        return true
      end
      return false unless item.voided?

      result = client_for(allocation).void_payroll_manual_allocation(
        allocation_id: allocation.remote_allocation_id,
        command_id: allocation.void_command_id,
        expected_version: allocation.remote_version,
        occurred_at: item.voided_at.iso8601,
        reason: "Cornerstone payroll item #{allocation.payroll_item_id} was voided"
      )
      persist_remote_transition!(allocation, "committed", "voided", result)
      true
    end

    def sync_issued!(allocation)
      return false unless allocation.payroll_item.reload.voided?

      # A delivered check may still be cashed after a software void. Keep
      # AIRE's paid claim until nonpayment/replacement evidence is reviewed.
      allocation.with_lock do
        if allocation.status == "issued"
          allocation.update!(
            last_sync_error: "Delivered check was voided in Cornerstone. Verify bank nonpayment or replacement before releasing these AIRE hours."
          )
        end
      end
      false
    end

    def persist_remote_transition!(allocation, from, to, result)
      remote = remote_allocation_acknowledgement!(result, expected_id: allocation.remote_allocation_id)
      allocation.with_lock do
        next unless allocation.status == from

        allocation.update!(status: to, remote_version: remote.fetch("version"),
                           last_sync_error: nil, last_synced_at: Time.current)
      end
    end

    def remote_allocation_acknowledgement!(result, expected_id: nil)
      remote = result.is_a?(Hash) ? result["manual_allocation"] : nil
      id = remote.is_a?(Hash) ? remote["id"].to_s : ""
      version = remote.is_a?(Hash) ? remote["version"] : nil
      valid_version = version.is_a?(Integer) && version >= 0
      unless id.match?(/\A[1-9]\d*\z/) && valid_version && (expected_id.nil? || id == expected_id.to_s)
        raise TimeTracking::Client::Error, "AIRE returned an invalid manual allocation acknowledgement; retry the sync"
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
      unless adjustment && adjustment["source_time_entry_version"].to_i == version &&
             adjustment["original_work_date"] == work_date.iso8601 &&
             regular <= BigDecimal(adjustment["regular_hours"].to_s) &&
             overtime <= BigDecimal(adjustment["overtime_hours"].to_s)
        raise Error, "AIRE no longer shows these exact unpaid hours. Refresh the manual hours check."
      end
    end

    def client_for(allocation)
      @clients_by_source ||= {}
      @clients_by_source[allocation.time_tracking_source_id] ||= begin
        source_client = TimeTracking::Client.new(allocation.time_tracking_source)
        linked = source_client.payroll_account_link(external_actor_id: actor.id)
          .dig("account_link", "connected") == true
        TimeTracking::Client.new(
          allocation.time_tracking_source,
          actor: (actor if linked),
          delegation: allocation.time_tracking_source.delegation_for(actor)
        )
      rescue TimeTracking::Client::Error
        TimeTracking::Client.new(
          allocation.time_tracking_source,
          delegation: allocation.time_tracking_source.delegation_for(actor)
        )
      end
    end

    def client_for_source
      @client_for_source ||= begin
        linked = TimeTracking::Client.new(source).payroll_account_link(external_actor_id: actor.id)
          .dig("account_link", "connected") == true
        TimeTracking::Client.new(source, actor: (actor if linked), delegation: source.delegation_for(actor))
      rescue TimeTracking::Client::Error
        TimeTracking::Client.new(source, delegation: source.delegation_for(actor))
      end
    end

    def delivered_check_event(allocation)
      item = allocation.payroll_item
      return unless item.effective_payment_delivery_method == "paper_check" && item.check_number.present?

      item.check_events.deliveries.where(check_number: item.check_number).order(:id).last
    end

    def decimal_hours!(value)
      raw = BigDecimal(value.to_s)
      raise Error, "Hours must be non-negative with at most two decimals" if raw.negative? || raw.round(2) != raw

      raw
    rescue ArgumentError
      raise Error, "Hours must be numeric"
    end
  end
end
