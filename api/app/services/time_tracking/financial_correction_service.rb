# frozen_string_literal: true

module TimeTracking
  # Replaces ownership of unchanged frozen work, not wages, cash or batch contents.
  class FinancialCorrectionService
    class Error < StandardError; end
    CAPABILITY = :payroll_obligation_correction_v1

    def initialize(pay_period:, actor: nil)
      @period = pay_period
      @actor = actor
    end

    def preview
      rows = plans
      { required: rows.any?, expected_digest: digest(rows), status: status(rows), items: rows.group_by { |row| row[:item].id }.map do |_id, group|
        row = group.first
        { payroll_item_id: row[:item].id, employee_name: row[:item].employee_full_name,
          original_pay_period_id: row[:predecessor].pay_period_id, original_payroll_item_id: row[:predecessor].id,
          corrected_pay_period_id: @period.id, work_start: group.map { |entry| entry[:allocation].original_work_date }.min.iso8601, work_end: group.map { |entry| entry[:allocation].original_work_date }.max.iso8601,
          regular_hours: group.sum { |entry| entry[:allocation].regular_hours }.to_f,
          overtime_hours: group.sum { |entry| entry[:allocation].overtime_hours }.to_f }
      end }
    rescue Client::Error => e
      raise Error, e.message
    end

    def confirm!(expected_digest:)
      acknowledgements = []
      ApplicationRecord.transaction do
        Company.lock.find(@period.company_id)
        @period.lock!
        raise Error, "Only an already committed native correction can connect corrected hours" unless @period.committed? && !@period.voided?
        raise Error, "Payroll organization does not match the reviewing operator" unless @actor && @actor.organization_id == @period.company.organization_id
        rows = plans
        raise Error, "No frozen corrected hours need connecting" if rows.empty?
        raise Error, "Corrected hours changed; review them again" unless ActiveSupport::SecurityUtils.secure_compare(digest(rows), expected_digest.to_s)
        acknowledgements = record!(rows)
      end
      acknowledgements.each do |acknowledgement|
        acknowledgement.last_error.present? ? acknowledgement.retry_financial! : acknowledgement.dispatch!
      end
      preview
    end

    def validate_before_commit!
      plans(committing: true)
      true
    end

    def record_commit!
      record!(plans)
    end


    # A zero/negative statement has no paper or bank instrument to retire. Its
    # financial reversal is the whole-period audit, not a synthetic CheckEvent.
    def self.instrumentless?(item)
      !item.net_pay.to_d.positive? && item.check_number.blank? && item.check_prepared_at.nil? &&
        item.check_printed_at.nil? && item.check_print_count.to_i.zero? &&
        item.check_events.empty? && item.check_reconciliation_events.empty? &&
        item.direct_deposit_payment_confirmation.nil? &&
        !item.aire_payroll_entry_acknowledgements.where(status: %w[payment_prepared payment_issued]).exists? &&
        !item.time_tracking_manual_allocations.where(status: "issued").exists?
    end

    def self.record_instrumentless_void!(pay_period:, void_event:)
      unless pay_period.voided? && (void_event.resulting_pay_period_id || void_event.pay_period_id) == pay_period.id && void_event.action_type == "void_initiated"
        raise Error, "Instrumentless Source void requires the actual whole-payroll reversal audit"
      end
      pay_period.payroll_items.flat_map do |item|
        next [] if item.voided? || !instrumentless?(item) || item.source_accounting_correction_linked?
        original = item.time_tracking_entry_allocations.includes(:time_tracking_import).filter_map do |row|
          next unless row.time_tracking_import.finalized_batch? && row.time_tracking_import.contract_version == "2.0" && row.verified_source_user_uuid.present?
          AirePayrollEntryAcknowledgement.record_from_rows!(rows: [ row ],
            source_event_key: "whole_payroll_void:#{void_event.id}:#{item.id}:#{row.source_time_entry_id}:#{row.line_key}",
            status: "payment_voided", occurred_at: void_event.created_at, payroll_item_id: item.id)
        end
        original + links_for(item).map do |link|
          AirePayrollEntryAcknowledgement.record_financial_payment!(link: link, key: "whole_payroll_void:#{void_event.id}",
            status: "payment_voided", occurred_at: void_event.created_at,
            payment_method: nil, payment_reference: nil, payment_effective_on: nil)
        end
      end
    end

    def self.required_for?(period)
      return false unless period.correction_run? && period.source_pay_period_id.present?
      service = new(pay_period: period)
      period.payroll_items.not_voided.any? do |item|
        origin = service.send(:origin_for, item)
        origin && (origin.time_tracking_entry_allocations.exists? || origin.time_tracking_financial_correction_links.exists? || service.send(:expected_frozen_source?, origin))
      end
    rescue Error
      true
    end

    def self.payment_blocker(item)
      require_payment_ready!(item)
      nil
    rescue Error => e
      e.message
    end

    def self.links_for(item)
      TimeTrackingFinancialCorrectionLink.where(payroll_item: item).includes(original_allocation: :time_tracking_import).to_a
    end

    def self.require_payment_ready!(item)
      return true unless item.pay_period.correction_run?
      service = new(pay_period: item.pay_period)
      rows = service.plans(item: item)
      return true if rows.empty?
      rows.each do |row|
        link = row[:link]
        raise Error, "Connect corrected hours and wait for Source confirmation before preparing or issuing payment" unless link&.accepted?
        Client.new(row[:allocation].time_tracking_source).validate_financial_correction_receipt!(link.accepted_receipt, expected: link.payload, historical: true)
      end
      true
    rescue Client::Error => e
      raise Error, "Source confirmation needs review: #{e.message}"
    end

    # Called under the same company/period locks as native commit or catch-up.
    def plans(committing: false, item: nil)
      return [] unless @period.correction_run? && @period.source_pay_period_id.present?
      raise Error, "Voided payroll cannot connect corrected hours" if @period.voided?
      unless committing || @period.committed?
        raise Error, "Commit the correction before connecting corrected hours"
      end
      items = @period.payroll_items.not_voided.order(:employee_id, :id)
      items = items.where(id: item.id) if item
      items.flat_map do |item|
        origin = origin_for(item)
        next [] unless origin
        allocations = origin.time_tracking_entry_allocations.includes(:time_tracking_import, :time_tracking_source).to_a
        allocations += self.class.links_for(origin).map(&:original_allocation) if allocations.empty?
        if allocations.empty?
          raise Error, "The original frozen Source allocation is missing; review payroll history" if expected_frozen_source?(origin)
          next []
        end
        raise Error, "Exact accounting corrections require their separate reviewed workflow" if origin.source_accounting_correction_linked? || item.source_accounting_correction_linked?
        sources = allocations.map(&:time_tracking_source).uniq(&:id)
        raise Error, "Mixed Source ownership requires review" unless sources.one?
        source = sources.first
        unless source.active? && source.remote_identity_pinned? && source.supports?(CAPABILITY)
          raise Error, "Use Test connection to verify that the connected Source supports corrected payroll ownership"
        end
        unless allocations.sum(&:regular_hours) == item.hours_worked.to_d && allocations.sum(&:overtime_hours) == item.overtime_hours.to_d
          raise Error, "Corrected REG and OT must preserve the exact frozen work; use the Source work correction workflow for changed hours"
        end
        allocations.map do |allocation|
          link = TimeTrackingFinancialCorrectionLink.find_by(original_allocation: allocation, payroll_item: item)
          predecessor = link&.predecessor_payroll_item || predecessor_for(allocation, item)
          ensure_successor_unissued!(item) unless link&.accepted?
          proof = financial_proof(predecessor, item, committing: committing)
          validate_frozen!(allocation)
          receipt = original_void_receipt!(allocation, predecessor)
          { allocation: allocation, item: item, predecessor: predecessor, proof: proof, void_receipt: receipt, link: link }
        end
      end
    rescue ArgumentError, ConnectionIdentity::Error, PayrollBatchPayloadValidator::Error => e
      raise Error, e.message
    end

    private

    def origin_for(item)
      origin = item.financial_correction_origin_item
      unless origin
        candidates = @period.source_pay_period.payroll_items.reportable.where(employee_id: item.employee_id).to_a
        if candidates.empty? && item.timekeeping_source.in?([ nil, "manual" ]) && item.timekeeping_context_snapshot.blank? &&
            !expected_frozen_source_in?(@period.source_pay_period, item.employee_id)
          return nil # Newly added unsourced payroll has no inherited frozen work.
        end
        raise Error, "Legacy correction ancestry is missing or ambiguous" unless candidates.one?
        origin = candidates.first
        unless item.timekeeping_context_snapshot.to_h == origin.timekeeping_context_snapshot.to_h
          raise Error, "Legacy correction work provenance changed; review original history"
        end
      end
      ancestry_periods = [ @period.source_pay_period_id ] + PayPeriodCorrectionEvent.where(
        pay_period_id: @period.source_pay_period_id, company_id: @period.company_id, action_type: "correction_run_committed").pluck(:resulting_pay_period_id)
      unless ancestry_periods.include?(origin.pay_period_id) && origin.company_id == item.company_id && origin.employee_id == item.employee_id
        raise Error, "Correction ancestry does not match this employee and payroll"
      end
      origin
    end

    def expected_frozen_source?(origin)
      expected_frozen_source_in?(origin.pay_period, origin.employee_id)
    end

    def expected_frozen_source_in?(period, employee_id)
      period.time_tracking_imports.where(status: "applied").any? do |import|
        next false unless import.finalized_batch?
        ids = TimeTrackingEmployeeMapping.where(time_tracking_source_id: import.time_tracking_source_id, employee_id: employee_id).pluck(:source_user_id)
        Array(import.raw_payload["employees"]).any? { |employee| ids.include?(employee["source_user_id"].to_s) }
      end
    end

    def predecessor_for(allocation, item)
      latest = TimeTrackingFinancialCorrectionLink.where(original_allocation: allocation).order(:id).last
      predecessor = latest ? latest.payroll_item : allocation.payroll_item
      raise Error, "Another corrective payroll already owns these Source hours" if predecessor.id == item.id
      predecessor
    end

    def ensure_successor_unissued!(item)
      if item.direct_deposit_payment_confirmation.present? || item.check_events.deliveries.exists? ||
          item.check_reconciliation_events.where(event_type: %w[cleared replacement_required]).exists? ||
          item.aire_payroll_entry_acknowledgements.where(status: "payment_issued").exists? ||
          item.time_tracking_manual_allocations.where(status: "issued").exists?
        raise Error, "This corrected payroll already has payment evidence; review its payment history before connecting hours"
      end
    end

    def financial_proof(predecessor, item, committing:)
      previous = predecessor.pay_period
      root = @period.source_pay_period
      unless previous.voided? && (predecessor.voided? || self.class.instrumentless?(predecessor)) && previous.company_id == @period.company_id && predecessor.employee_id == item.employee_id
        raise Error, "The prior whole payroll and check must be financially voided before connecting a successor"
      end
      raise Error, "Paid or unsupported prior payment cannot be replaced by a Source linkage" if PayrollRevisionPaymentPreflight.new(pay_period: previous).call[:blockers].any? { |message| message != "Only a committed, active payroll can be reversed" }
      unless LoanTransaction.payments.where(payroll_item_id: previous.payroll_items.select(:id), source: "payroll").all? { |payment| payment.reversal.present? }
        raise Error, "Prior payroll loan effects have not been reversed"
      end
      postings = previous.payroll_liability_postings.source_postings.to_a
      raise Error, "Prior payroll accounting reversal is missing" if postings.empty? || postings.any? { |posting| !posting.reversed? }
      voids = PayPeriodCorrectionEvent.where(company_id: @period.company_id, action_type: "void_initiated").select do |event|
        (event.resulting_pay_period_id || event.pay_period_id) == previous.id
      end
      created = PayPeriodCorrectionEvent.where(company_id: @period.company_id, action_type: "correction_run_created", resulting_pay_period_id: @period.id).to_a
      committed = PayPeriodCorrectionEvent.where(company_id: @period.company_id, action_type: "correction_run_committed", resulting_pay_period_id: @period.id).to_a
      raise Error, "Whole-payroll correction audit chain is missing or ambiguous" unless voids.one? && created.one? && (committing || committed.one?)
      unless created.first.pay_period_id == root.id && (committing || committed.first.pay_period_id == root.id)
        raise Error, "Correction audit chain does not match the original payroll"
      end
      { "version" => 1, "kind" => "whole_payroll_void_and_corrective_commit", "root_pay_period_id" => root.id.to_s,
        "voided_pay_period_id" => previous.id.to_s, "successor_pay_period_id" => @period.id.to_s,
        "predecessor_payroll_item_id" => predecessor.id.to_s, "successor_payroll_item_id" => item.id.to_s,
        "void_event_id" => voids.first.id.to_s, "correction_created_event_id" => created.first.id.to_s,
        "successor_committed_event_id" => committed.first&.id&.to_s,
        "reversal_posting_ids" => postings.map(&:reversal_posting).sort_by(&:id).map { |posting| posting.id.to_s } }
    end

    def validate_frozen!(row)
      import = row.time_tracking_import
      source = row.time_tracking_source
      OriginalAllocationProof.new(payroll_item: row.payroll_item, source: source, source_user_id: row.source_user_id,
        source_user_uuid: row.verified_source_user_uuid).call
      raise Error, "Source employee identity is unverified" if row.verified_source_user_uuid.blank?
      raise Error, "The frozen batch identity changed" unless import.external_batch_checksum == import.raw_payload.dig("export", "checksum")
      employee = Array(import.raw_payload["employees"]).find { |entry| entry["source_user_id"].to_s == row.source_user_id }
      line = employee.fetch("adjustments").find { |entry| entry["source_time_entry_id"].to_s == row.source_time_entry_id && entry["line_key"] == row.line_key }
      raise Error, "The frozen Source work version is missing" unless line && line["source_time_entry_version"].is_a?(Integer) && line["source_time_entry_version"] >= 0
    end

    def original_void_receipt!(allocation, predecessor)
      receipt = AirePayrollEntryAcknowledgement.where(payroll_item: predecessor, time_tracking_import_id: allocation.time_tracking_import_id,
        source_time_entry_id: allocation.source_time_entry_id, source_line_key: allocation.line_key, status: "payment_voided").order(:id).last
      unless receipt && receipt.line_contract? && receipt.source_user_uuid == allocation.verified_source_user_uuid &&
        receipt.total_hours == allocation.total_hours && receipt.regular_hours == allocation.regular_hours && receipt.overtime_hours == allocation.overtime_hours
        raise Error, "The prior exact Source void receipt is missing"
      end
      receipt
    end

    def digest(rows)
      CanonicalPayload.checksum(rows.map do |row|
        { allocation: row[:allocation].attributes, target: row[:item].attributes,
          predecessor: row[:predecessor].attributes, proof: row[:proof], void_event_id: row[:void_receipt].event_id }
      end)
    end

    def status(rows)
      return "not_required" if rows.empty?
      return "confirmed" if rows.all? do |row|
        row[:link]&.accepted? && Client.new(row[:allocation].time_tracking_source).validate_financial_correction_receipt!(row[:link].accepted_receipt, expected: row[:link].payload, historical: true)
      end
      return "failed" if rows.any? { |row| row[:link]&.aire_payroll_entry_acknowledgements&.any? { |ack| ack.last_error.present? } }
      rows.any? { |row| row[:link] } ? "pending" : "needs_connection"
    end

    def record!(rows)
      rows.map do |row|
        existing = row[:link]
        if existing
          existing.aire_payroll_entry_acknowledgements.where(status: "committed").first!
        else
          allocation = row[:allocation]
          import = allocation.time_tracking_import
          employee = Array(import.raw_payload["employees"]).find { |entry| entry["source_user_id"].to_s == allocation.source_user_id }
          frozen = employee.fetch("adjustments").find { |line| line["line_key"] == allocation.line_key && line["source_time_entry_id"].to_s == allocation.source_time_entry_id }
          version = frozen["source_time_entry_version"]
          raise Error, "The frozen Source work version is missing" unless version.is_a?(Integer) && version >= 0
          command_id = SecureRandom.uuid
          event_id = SecureRandom.uuid
          payload = {
            "event_id" => event_id, "status" => "committed", "occurred_at" => Time.current.utc.iso8601(6), "external_system" => "cornerstone_payroll",
            "external_pay_period_id" => @period.id.to_s, "external_payroll_item_id" => row[:item].id.to_s, "contract_version" => "2.0",
            "source_time_entry_id" => allocation.source_time_entry_id, "source_user_uuid" => allocation.verified_source_user_uuid,
            "source_line_key" => allocation.line_key, "source_kind" => allocation.source_kind,
            "total_hours" => allocation.total_hours.to_s("F"), "regular_hours" => allocation.regular_hours.to_s("F"), "overtime_hours" => allocation.overtime_hours.to_s("F"), "metadata" => {},
            "obligation_correction" => { "contract" => CAPABILITY.to_s, "command_id" => command_id,
              "source_instance_id" => allocation.time_tracking_source.expected_source_instance_id,
              "batch_checksum" => import.external_batch_checksum, "source_work_date" => allocation.original_work_date.iso8601,
              "source_time_entry_version" => version, "predecessor" => { "external_pay_period_id" => row[:predecessor].pay_period_id.to_s,
                "external_payroll_item_id" => row[:predecessor].id.to_s, "payment_voided_event_id" => row[:void_receipt].event_id },
              "successor" => { "external_pay_period_id" => @period.id.to_s, "external_payroll_item_id" => row[:item].id.to_s }, "financial_assertion" => row[:proof] }
          }
          link = TimeTrackingFinancialCorrectionLink.create!(original_allocation: allocation, predecessor_payroll_item: row[:predecessor], payroll_item: row[:item],
            command_id: command_id, event_id: event_id, payload: payload, request_digest: CanonicalPayload.checksum(payload))
          AirePayrollEntryAcknowledgement.record_for_financial_link!(link: link, payload: payload, dependencies: [ row[:void_receipt].id ])
        end
      end
    end
  end
end
