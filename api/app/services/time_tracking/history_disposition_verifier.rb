# frozen_string_literal: true

module TimeTracking
  # This approves accounting coverage only. It has no write or payment API.
  class HistoryDispositionVerifier
    TYPES = %w[historical_baseline legacy_frozen_batch_baseline pending_review owed not_payable no_payable_hours payment_evidence_pending].freeze
    LABELS = {
      "historical_baseline" => "Already represented in manual payroll; delivery not asserted",
      "legacy_frozen_batch_baseline" => "Legacy frozen representation; lower-strength unchanged-source evidence; approval and delivery unchanged",
      "pending_review" => "Pending accounting review; approval unchanged",
      "owed" => "Genuinely owed; explicit routing still required",
      "not_payable" => "Denied; remains not payable",
      "no_payable_hours" => "Zero payable hours",
      "payment_evidence_pending" => "Reported payment held pending exact evidence"
    }.freeze
    SOURCE_FIELDS = %w[version work_date hours source_user_uuid employee category state history_evidence].freeze

    def initialize(source:, company:, actor:, client:)
      @source, @company, @actor, @client = source, company, actor, client
      @batches = {}
    end

    def refresh_runs!
      # One fresh local read per coverage pass, including the completion lock.
      # Do not perform a company/run query for each of thousands of lines.
      @runs = @company.pay_periods.where(status: "committed").index_by { |run| run.id.to_s }
      @employees = @source.time_tracking_employee_mappings.where(company: @company).index_by(&:source_user_uuid)
      @run_hours = PayrollItem.where(company: @company, pay_period_id: @runs.values.map(&:id))
        .group(:pay_period_id, :employee_id).pluck(:pay_period_id, :employee_id, Arel.sql("SUM(hours_worked)"), Arel.sql("SUM(overtime_hours)"))
        .to_h { |run_id, employee_id, regular, overtime| [ [ run_id.to_s, employee_id ], [ regular, overtime ] ] }
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
      when "legacy_frozen_batch_baseline"
        unallocated && baseline_verified?(baseline, current, legacy_frozen: true)
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

    def baseline_verified?(lines, current, legacy_frozen: false)
      refresh_runs! unless @runs
      return false if lines.empty? || lines.map { |line| line.fetch("batch_id") }.uniq.length != 1
      return false unless lines.map { |line| line.fetch("line_key") }.uniq.length == lines.length
      return false unless lines.sum { |line| decimal(line.fetch("total_hours")) } == decimal(current.fetch("hours"))

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
        hours = @run_hours[[ run_id, mapping.employee_id ]]
        # Manual runs aggregate multiple source lines into one or more earnings.
        # Reconcile the complete frozen employee balance, never an entry to a whole item.
        frozen_lines = source_employee.fetch("adjustments")
        next false unless hours && hours.map { |value| decimal(value) } ==
          %w[regular_hours overtime_hours].map { |key| frozen_lines.sum { |row| decimal(row.fetch(key)) } }
        frozen = frozen_lines.find do |row|
          row["source_time_entry_id"] == current.fetch("id") && row["line_key"] == line.fetch("line_key")
        end
        frozen && frozen["source_time_entry_version"] == line.fetch("source_time_entry_version") &&
          frozen["original_work_date"] == line.fetch("work_date") && frozen["category"] == line.fetch("category") &&
          frozen["source_kind"] == line.fetch("source_kind") &&
          %w[total_hours regular_hours overtime_hours].all? { |key| decimal(frozen.fetch(key)) == decimal(line.fetch(key)) }
      end
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
