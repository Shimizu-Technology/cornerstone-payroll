# frozen_string_literal: true

module TimeTracking
  # This approves accounting coverage only. It has no write or payment API.
  class HistoryDispositionVerifier
    TYPES = %w[historical_baseline historical_baseline_pending_overtime legacy_frozen_batch_baseline pending_review pending_overtime owed not_payable no_payable_hours payment_evidence_pending].freeze
    LABELS = {
      "historical_baseline" => "Already represented in manual payroll; delivery not asserted",
      "historical_baseline_pending_overtime" => "Represented regular hours plus exact frozen overtime hold; overtime approval and payment unchanged",
      "legacy_frozen_batch_baseline" => "Legacy frozen representation; lower-strength unchanged-source evidence; approval and delivery unchanged",
      "pending_overtime" => "Frozen unpaid overtime awaiting approval; no payment asserted",
      "pending_review" => "Pending accounting review; approval unchanged",
      "owed" => "Genuinely owed; explicit routing still required",
      "not_payable" => "Denied; remains not payable",
      "no_payable_hours" => "Zero payable hours",
      "payment_evidence_pending" => "Reported payment held pending exact evidence"
    }.freeze
    SOURCE_FIELDS = %w[version work_date hours source_user_uuid employee category state history_evidence].freeze

    def initialize(source:, company:, actor:, client:, rounding_acknowledgements: [], component_bindings: [])
      @source, @company, @actor, @client = source, company, actor, client
      @batches = {}
      @rounding_acknowledgements, @component_bindings = rounding_acknowledgements, component_bindings
    end

    def refresh_runs!(run_ids: nil)
      # One fresh local read per coverage pass, including the completion lock.
      # Do not perform a company/run query for each of thousands of lines.
      runs = @company.pay_periods.where(status: "committed")
      runs = runs.where(id: run_ids) unless run_ids.nil?
      @runs = runs.index_by { |run| run.id.to_s }
      @employees = @source.time_tracking_employee_mappings.where(company: @company).index_by(&:source_user_uuid)
      @run_items = PayrollItem.where(company: @company, pay_period_id: @runs.values.map(&:id))
        .includes(:payroll_item_earnings, :pay_period).order(:id).to_a.group_by { |item| item.pay_period_id.to_s }
      @run_checksums = @run_items.to_h do |id, items|
        [ id, CanonicalPayload.checksum({ "run" => @runs.fetch(id).attributes,
          "items" => items.map { |item| { "item" => item.attributes, "earnings" => item.payroll_item_earnings.sort_by(&:id).map(&:attributes) } } }) ]
      end
      @rounding_review = HistoricalRoundingReview.new(source: @source, actor: @actor,
        acknowledgements: @rounding_acknowledgements, component_bindings: @component_bindings)
      @batches = {}
      @source_inventory_checksums = nil
    end

    def discover_rounding_variances!(inventory)
      run_ids = inventory.flat_map do |row|
        Array(row.dig("history_evidence", "baseline_lines")).filter_map { |line| line.dig("processing", "external_pay_period_id") }
      end.uniq
      refresh_runs!(run_ids: run_ids)
      @source_inventory_checksums = inventory.group_by { |row| row.fetch("source_user_uuid") }.transform_values do |rows|
        CanonicalPayload.checksum(rows.sort_by { |row| row.fetch("id").to_s }.map { |row| row.slice("id", *SOURCE_FIELDS) })
      end
      inventory.each do |row|
        lines = row.dig("history_evidence", "baseline_lines")
        next if lines.blank?

        legacy = lines.all? { |line| line["payable_content_checksum"].blank? && line["legacy_frozen_evidence"].present? }
        unless baseline_verified?(lines, row, legacy_frozen: legacy, discover: true) || overtime_hold_verified?(row, discover: true)
          @rounding_review.blockers << { "source_time_entry_id" => row.fetch("id"), "reason" => "Baseline evidence or earning component requires review" }
        end
      end
      rounding_variances
    end

    def rounding_variances
      @rounding_review&.table || []
    end

    def rounding_review_blockers
      @rounding_review&.blockers&.uniq || []
    end

    def rounding_acknowledgements_valid?
      @rounding_review&.acknowledgements_valid? || (@rounding_acknowledgements == [] && @component_bindings == [])
    end

    def verified?(disposition, current)
      return false unless disposition.is_a?(Hash) && TYPES.include?(disposition["disposition"]) &&
        disposition["actor_id"] == @actor.id && disposition["reason"].is_a?(String) &&
        disposition["reason"].strip.length.between?(10, 2_000) && disposition["evidence"].is_a?(String) &&
        disposition["evidence"].strip.length.between?(10, 2_000) && current["source_user_uuid"].present? &&
        disposition["source_instance_id"] == @source.expected_source_instance_id &&
        disposition["source_time_entry_id"] == current.fetch("id") &&
        disposition["source_time_entry_version"] == current.fetch("version") &&
        disposition["source_user_uuid"] == current.fetch("source_user_uuid") &&
        disposition["source"] == current.slice(*SOURCE_FIELDS) &&
        current.key?("work_date") && current.key?("category") &&
        current["state"].is_a?(Hash) && current["state"].key?("approval_status")

      evidence = current.fetch("history_evidence")
      return false unless evidence.fetch("payable_content_checksum").match?(/\A[0-9a-f]{64}\z/) &&
        evidence["baseline_lines"].is_a?(Array) && evidence["active_manual_allocation_ids"].is_a?(Array) &&
        evidence["active_cases"].is_a?(Array)

      baseline = evidence.fetch("baseline_lines")
      unallocated = evidence.fetch("active_manual_allocation_ids").empty? && evidence["payment_attestation"].nil?
      unheld = evidence.fetch("active_cases").none? { |record| record["status"].in?(%w[open scheduled]) }
      pending = current.dig("state", "approval_status").in?([ nil, "pending" ])
      case disposition.fetch("disposition")
      when "historical_baseline"
        unallocated && !pending && baseline_verified?(baseline, current)
      when "historical_baseline_pending_overtime"
        unallocated && unheld && overtime_hold_verified?(current)
      when "legacy_frozen_batch_baseline"
        unallocated && baseline_verified?(baseline, current, legacy_frozen: true)
      when "pending_overtime"
        unallocated && unheld && baseline.empty? && overtime_hold_verified?(current)
      when "pending_review"
        unallocated && unheld && pending && (baseline.empty? || baseline_verified?(baseline, current))
      when "owed"
        unallocated && baseline.empty? && decimal(current.fetch("hours")).positive? &&
          current.dig("state", "status") == "completed" && current.dig("state", "approval_status") == "approved" &&
          current.dig("lifecycle", "status") == "ready_for_cutoff" &&
          evidence.fetch("active_cases").one? && evidence.fetch("active_cases").all? do |record|
            record["version"] == current.fetch("version") && record["source_user_uuid"] == current.fetch("source_user_uuid") &&
              record["status"].in?(%w[open scheduled]) && decimal(record.fetch("held_total_hours")) == decimal(current.fetch("hours"))
          end
      when "not_payable"
        unallocated && unheld && baseline.empty? && current.dig("state", "approval_status") == "denied" &&
          current.dig("lifecycle", "status") == "not_payable"
      when "no_payable_hours"
        unallocated && unheld && baseline.empty? && decimal(current.fetch("hours")).zero?
      when "payment_evidence_pending"
        report = evidence["payment_attestation"]
        baseline.empty? && evidence.fetch("active_manual_allocation_ids").empty? && report.is_a?(Hash) &&
          report["source_changed"] == false && report["id"].present? &&
          decimal(report.fetch("hours")) == decimal(current.fetch("hours")) &&
          current.dig("lifecycle", "status") == "payment_attested_pending_evidence"
      end
    rescue KeyError, ArgumentError, TypeError, NoMethodError
      false
    end

    private

    def baseline_verified?(lines, current, legacy_frozen: false, discover: false, covered_hours: nil, allow_overtime_hold: false)
      refresh_runs! unless @runs
      return false if lines.empty? || lines.map { |line| line.fetch("batch_id") }.uniq.length != 1
      return false unless lines.map { |line| line.fetch("line_key") }.uniq.length == lines.length
      return false unless lines.sum { |line| decimal(line.fetch("total_hours")) } == decimal(covered_hours || current.fetch("hours"))

      lines.all? do |line|
        processing = line.fetch("processing")
        run_id = processing.fetch("external_pay_period_id").to_s
        run = @runs ? @runs[run_id] : @company.pay_periods.find_by(id: run_id)
        next false unless run&.committed? && processing["status"] == "committed" &&
          processing["external_system"] == "cornerstone_payroll_manual" && line["processing_conflict"] == false &&
          (legacy_frozen ? legacy_frozen_verified?(line, current) : line["current_content_matches"] == true) &&
          line["source_user_uuid"] == current.fetch("source_user_uuid") &&
          line["source_time_entry_id"] == current.fetch("id") && line["work_date"] == current.fetch("work_date") &&
          run.start_date.iso8601 == line.fetch("batch_start_date") && run.end_date.iso8601 == line.fetch("batch_end_date") &&
          decimal(line.fetch("regular_hours")) + decimal(line.fetch("overtime_hours")) == decimal(line.fetch("total_hours"))

        payload = batch(line.fetch("batch_id"))
        next false unless payload.dig("export", "checksum") == line.fetch("batch_checksum")
        unless allow_overtime_hold
          next false if Array(payload["exclusions"]).any? do |exclusion|
            exclusion["source_time_entry_id"] == current.fetch("id") && decimal(exclusion.fetch("held_total_hours")).positive?
          end
        end
        if legacy_frozen
          next false unless Time.iso8601(payload.fetch("export").fetch("finalized_at_precise")) ==
            Time.iso8601(line.fetch("legacy_frozen_evidence").fetch("batch_finalized_at"))
        end
        source_employee = payload.fetch("employees").find do |row|
          if line["identity_basis"] == "reviewed_legacy_owner"
            row["source_user_uuid"].blank? && row["source_user_id"] == line.fetch("source_user_id") &&
              current.dig("employee", "id") == line.fetch("source_user_id")
          else
            row["source_user_uuid"] == current.fetch("source_user_uuid")
          end
        end
        mapping = @employees[current.fetch("source_user_uuid")]
        next false unless source_employee && mapping && mapping.source_user_id == current.dig("employee", "id")
        frozen_lines = source_employee.fetch("adjustments")
        frozen = frozen_lines.find do |row|
          row["source_time_entry_id"] == current.fetch("id") && row["line_key"] == line.fetch("line_key")
        end
        exact_line = frozen && frozen["source_time_entry_version"] == line.fetch("source_time_entry_version") &&
          frozen["original_work_date"] == line.fetch("work_date") && frozen["category"] == line.fetch("category") &&
          frozen["source_kind"] == line.fetch("source_kind") &&
          %w[total_hours regular_hours overtime_hours].all? { |key| decimal(frozen.fetch(key)) == decimal(line.fetch(key)) }
        next false unless exact_line

        @rounding_review.verify!(batch: payload, run: run, mapping: mapping, source_employee: source_employee,
          items: Array(@run_items[run_id]).select { |item| item.employee_id == mapping.employee_id },
          run_checksum: @run_checksums.fetch(run_id),
          source_inventory_checksum: @source_inventory_checksums&.fetch(current.fetch("source_user_uuid")) ||
            CanonicalPayload.checksum([ current.slice("id", *SOURCE_FIELDS) ]), discover: discover)
      end
    end

    def overtime_hold_verified?(current, discover: false)
      return false unless current.dig("state", "status") == "completed" &&
        current.dig("state", "approval_status") == "approved" &&
        current.dig("state", "overtime_status").in?([ nil, "none", "pending" ])

      lines = current.fetch("history_evidence").fetch("baseline_lines")
      return full_overtime_hold_verified?(current) if lines.empty?
      return false if lines.map { |line| line.fetch("batch_id") }.uniq.length != 1
      return false unless lines.all? { |line| decimal(line.fetch("overtime_hours")).zero? }

      payload = batch(lines.first.fetch("batch_id"))
      exclusions = Array(payload["exclusions"]).select { |row| row["source_time_entry_id"] == current.fetch("id") }
      return false unless exclusions.one?

      hold = exclusions.sole
      held = decimal(hold.fetch("held_total_hours"))
      represented = lines.sum { |line| decimal(line.fetch("total_hours")) }
      exact_hold = hold["reason"] == "pending_overtime" && hold["allocation_review_reason"].nil? &&
        hold["source_user_uuid"] == current.fetch("source_user_uuid") &&
        hold["source_user_id"] == current.dig("employee", "id") && hold["original_work_date"] == current.fetch("work_date") &&
        hold["category"] == lines.first.fetch("category") && decimal(hold.fetch("held_regular_hours")).zero? &&
        held.positive? && decimal(hold.fetch("held_overtime_hours")) == held && represented.positive? &&
        represented + held == decimal(current.fetch("hours"))
      exact_hold && baseline_verified?(lines, current, discover: discover, covered_hours: represented, allow_overtime_hold: true)
    end

    def full_overtime_hold_verified?(current)
      proof = current.fetch("history_evidence").fetch("pending_overtime")
      return false unless proof.is_a?(Hash) && proof["kind"] == "pending_overtime" &&
        proof["source_time_entry_version"] == current.fetch("version") &&
        proof["payable_content_checksum"] == current.dig("history_evidence", "payable_content_checksum") &&
        decimal(proof.fetch("represented_regular_hours")).zero?

      payload = batch(proof.fetch("batch_id"))
      return false unless payload.dig("export", "checksum") == proof.fetch("batch_checksum")
      return false if payload.fetch("employees").any? do |employee|
        employee.fetch("adjustments").any? { |line| line["source_time_entry_id"] == current.fetch("id") }
      end
      exclusions = payload.fetch("exclusions").select { |row| row["source_time_entry_id"] == current.fetch("id") }
      return false unless exclusions.one?

      hold = exclusions.sole
      hold.except("display_name", "email") == proof.fetch("frozen_exclusion") &&
        hold["reason"] == "pending_overtime" && hold["allocation_review_reason"].nil? &&
        hold["source_user_id"] == current.dig("employee", "id") && hold["source_user_uuid"] == current.fetch("source_user_uuid") &&
        hold["original_work_date"] == current.fetch("work_date") &&
        %w[id key name].all? { |key| hold.dig("category", key).to_s == current.dig("category", key).to_s } &&
        decimal(hold.fetch("held_regular_hours")).zero? && decimal(hold.fetch("held_total_hours")).positive? &&
        decimal(hold.fetch("held_total_hours")) == decimal(current.fetch("hours")) &&
        decimal(hold.fetch("held_overtime_hours")) == decimal(current.fetch("hours"))
    end

    def legacy_frozen_verified?(line, current)
      proof = line.fetch("legacy_frozen_evidence")
      finalized = Time.iso8601(proof.fetch("batch_finalized_at"))
      finalized <= Time.current && proof["kind"] == "legacy_frozen_batch_baseline" &&
        proof["evidence_strength"] == "retained_snapshot_and_unchanged_source" &&
        proof["eligible"] == true && proof["blockers"] == [] && proof["payload_checksum_verified"] == true &&
        proof["source_user_id"] == current.dig("employee", "id") && proof["source_user_uuid"] == current.fetch("source_user_uuid") &&
        proof["source_version"] == current.fetch("version") && proof["later_edit_audit_count"] == 0 &&
        Time.iso8601(proof.fetch("source_created_at")) <= finalized && Time.iso8601(proof.fetch("source_updated_at")) <= finalized &&
        (%w[user_id work_date hours time_category] - proof.fetch("retained_snapshot_fields")).empty? &&
        %w[source_observation_checksum revision_observation_checksum].all? { |key| proof.fetch(key).match?(/\A[0-9a-f]{64}\z/) } &&
        line.fetch("snapshot_checksum").match?(/\A[0-9a-f]{64}\z/)
    end

    def batch(id)
      @batches[id] ||= begin
        payload = @client.payroll_batch(batch_id: id)
        PayrollBatchPayloadValidator.new(payload: payload, start_date: payload.fetch("start_date"),
          end_date: payload.fetch("end_date"), allow_legacy_uncategorized: true).validate!
        raise ArgumentError, "Historical batch ID differs" unless payload.fetch("batch_id") == id

        payload
      end
    end

    def decimal(value)
      number = BigDecimal(value.to_s)
      raise ArgumentError unless number.finite? && number >= 0

      number
    end
  end
end
