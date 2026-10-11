# frozen_string_literal: true

module TimeTracking
  # Frozen allocations stay with their import owner. Financial links establish
  # the separately proven payment owner of the same complete frozen work union.
  class PaidCorrectionTarget
    def initialize(allocation:, source:, line:)
      @allocation = allocation
      @source = source
      @line = line
    end

    def resolve
      origin = @allocation.payroll_item.reload
      proof = OriginalAllocationProof.new(payroll_item: origin, source: @source,
        source_user_id: @allocation.source_user_id, source_user_uuid: @allocation.verified_source_user_uuid).call
      allocations = proof.fetch(:allocations)
      links = TimeTrackingFinancialCorrectionLink.where(original_allocation_id: allocations.map(&:id)).order(:id).to_a
      chains = allocations.map { |row| chain_for(row, links.select { |link| link.original_allocation_id == row.id }) }
      paths = chains.map { |chain| chain.map { |link| [ link.predecessor_payroll_item_id, link.payroll_item_id ] } }
      raise ArgumentError, "Frozen work has mixed financial successors; review its whole allocation union" unless paths.uniq.one?
      chain = chains.first
      target = chain.last&.payroll_item || origin
      financial_proofs = chains.flatten.uniq(&:id).sort_by(&:id).map { |link| validate_link!(link) }
      chain.map(&:payroll_item).uniq(&:id).each do |item|
        unless FinancialCorrectionService.links_for(item).map(&:original_allocation_id).sort == allocations.map(&:id).sort
          raise ArgumentError, "Accepted successor does not cover the complete frozen work union"
        end
      end
      unless target.company_id == origin.company_id && target.employee_id == origin.employee_id &&
        target.hours_worked.to_d == allocations.sum(&:regular_hours) && target.overtime_hours.to_d == allocations.sum(&:overtime_hours) &&
        target.pay_rate.to_d == origin.pay_rate.to_d && target.employment_type == origin.employment_type &&
        target.timekeeping_context_snapshot == origin.timekeeping_context_snapshot &&
        (target.pay_period.can_issue_corrective_paycheck? || (chain.any? && target.pay_period.correction_run?))
        raise ArgumentError, "Current paid target has changed work, rate or payroll ownership"
      end
      payment = OriginalPaymentProof.call(target, financial_target: chain.any? ? self : nil)
      evidence = { "version" => 1, "origin_payroll_item_id" => origin.id, "target_payroll_item_id" => target.id,
        "origin_work" => proof.fetch(:evidence).deep_stringify_keys,
        "target" => target.attributes, "target_period" => target.pay_period.attributes,
        "financial_links" => chains.flatten.uniq(&:id).sort_by(&:id).map(&:attributes),
        "financial_proofs" => financial_proofs.map(&:deep_stringify_keys),
        "current_payment" => payment.deep_stringify_keys }
      { origin: origin, target: target, original_proof: proof.fetch(:evidence), payment_proof: payment,
        evidence: JSON.parse(JSON.generate(CanonicalPayload.canonicalize(evidence))), linked: chain.any? }
    rescue FinancialCorrectionService::Error, Client::Error => e
      raise ArgumentError, e.message
    end

    # A posted disposition retains its issuance proof when ordinary clearing
    # history appends. Preview/confirmation still digest the complete live proof.
    def matches_saved_evidence?(stored)
      return false unless stored.is_a?(Hash)
      current = resolve.fetch(:evidence)
      saved_payment = stored["current_payment"]
      payment = current["current_payment"]
      if payment["method"] == "paper_check" && saved_payment.is_a?(Hash) && saved_payment["method"] == "paper_check"
        saved = saved_payment["reconciliation"]
        rows = payment.fetch("reconciliation")
        return false unless saved.is_a?(Array)
        appended = rows.drop(saved.length)
        unless rows.first(saved.length) == saved && appended.all? do |row|
          event = CheckReconciliationEvent.find_by(id: row.fetch("id"))
          event && event.event_type.in?(%w[cleared clearing_reversed]) && event.valid? && event.payroll_item_id == current["target_payroll_item_id"] &&
            event.check_number == payment["check_number"] && event.amount.to_d == current["target"]["net_pay"].to_d
        end
          return false
        end
        payment["reconciliation"] = saved
      end
      CanonicalPayload.checksum(current) == CanonicalPayload.checksum(stored)
    end

    # Called after the company lock: native succession, void and payment paths
    # serialize on these same periods/items. Lock proof rows before revalidation.
    def lock!
      origin = @allocation.payroll_item
      allocations = origin.time_tracking_entry_allocations.order(:id).to_a
      links = TimeTrackingFinancialCorrectionLink.where(original_allocation_id: allocations.map(&:id)).order(:id).lock.load
      item_ids = ([ origin.id ] + links.flat_map { |link| [ link.predecessor_payroll_item_id, link.payroll_item_id ] }).uniq
      period_ids = PayrollItem.where(id: item_ids).pluck(:pay_period_id)
      PayPeriod.where(id: period_ids).order(:id).lock.load
      PayrollItem.where(id: item_ids).order(:id).lock.load
      TimeTrackingImport.where(id: allocations.map(&:time_tracking_import_id)).order(:id).lock.load
      TimeTrackingEntryAllocation.where(id: allocations.map(&:id)).order(:id).lock.load
      CheckEvent.where(payroll_item_id: item_ids).order(:id).lock.load
      CheckReconciliationEvent.where(payroll_item_id: item_ids).order(:id).lock.load
      DirectDepositPaymentConfirmation.where(payroll_item_id: item_ids).order(:id).lock.load
      self
    end

    # This object, rather than an API-provided flag/hash, authorizes the narrow
    # negative accounting exception for a paid native correction run.
    def assert_for!(item, inputs)
      context = resolve
      frozen = Array(context[:original_proof][:allocations]).find { |row| row["id"] == @allocation.id }
      origin_line = OriginalAllocationProof.new(payroll_item: context[:origin], source: @source,
        source_user_id: @allocation.source_user_id, source_user_uuid: @allocation.verified_source_user_uuid).call[:lines]
        .find { |row| row["source_time_entry_id"].to_s == @allocation.source_time_entry_id && row["line_key"] == @allocation.line_key }
      unless frozen && origin_line && @line["source_time_entry_id"].to_s == @allocation.source_time_entry_id &&
        @line["line_key"] == @allocation.line_key && @line["original_work_date"] == @allocation.original_work_date.iso8601 &&
        OriginalAllocationProof.earning_identity(@line) == OriginalAllocationProof.earning_identity(origin_line) &&
        @line["source_time_entry_version"].is_a?(Integer) && origin_line["source_time_entry_version"].is_a?(Integer) &&
        @line["source_time_entry_version"] > origin_line["source_time_entry_version"] &&
        @allocation.regular_hours + @line["regular_hours"].to_d >= 0 && @allocation.overtime_hours + @line["overtime_hours"].to_d >= 0
        raise ArgumentError, "The accounting target requires exact frozen identity, category, version and bounded line hours"
      end
      expected = { hours_worked: item.hours_worked.to_d + @line.fetch("regular_hours").to_d,
        overtime_hours: item.overtime_hours.to_d + @line.fetch("overtime_hours").to_d }
      unless context[:target].id == item.id && inputs.keys.sort == expected.keys.sort &&
        inputs.all? { |key, value| value.to_d == expected.fetch(key) && value.to_d >= 0 } &&
        @line["source_kind"] == "correction" && @line["total_hours"].to_d.negative? &&
        @line["total_hours"].to_d == @line["regular_hours"].to_d + @line["overtime_hours"].to_d &&
        %w[total_hours regular_hours overtime_hours].all? { |key| @line[key].to_d.finite? } &&
        @line["regular_hours"].to_d <= 0 && @line["overtime_hours"].to_d <= 0
        raise ArgumentError, "Only the proven exact negative Source work adjustment can correct this paid target"
      end
      context
    end

    private

    def chain_for(allocation, links)
      owner = allocation.payroll_item_id
      chain = []
      seen = [ owner ]
      loop do
        successors = links.select { |link| link.predecessor_payroll_item_id == owner }
        break if successors.empty?
        raise ArgumentError, "Financial successor is ambiguous" unless successors.one?
        link = successors.first
        raise ArgumentError, "Financial successor is pending Source confirmation" unless link.accepted?
        raise ArgumentError, "Financial succession contains a cycle" if seen.include?(link.payroll_item_id)
        chain << link
        owner = link.payroll_item_id
        seen << owner
      end
      raise ArgumentError, "Financial succession contains disconnected or foreign ownership" unless chain.size == links.size
      chain
    end

    def validate_link!(link)
      unless link.valid? && link.payroll_item.financial_correction_origin_item_id == link.predecessor_payroll_item_id &&
        link.payload.dig("obligation_correction", "predecessor", "external_pay_period_id") == link.predecessor_payroll_item.pay_period_id.to_s
        raise ArgumentError, "Financial successor ancestry or immutable command proof changed"
      end
      FinancialCorrectionService.new(pay_period: link.payroll_item.pay_period).accepted_chain_proof!(link)
    end
  end
end
