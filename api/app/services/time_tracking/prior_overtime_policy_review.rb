# frozen_string_literal: true

module TimeTracking
  # AIRE performs the preserved production calculation. Payroll authenticates
  # its inputs against fresh inventory and keeps every existing baseline fence.
  class PriorOvertimePolicyReview
    KIND = "paid_under_prior_daily_weekly_ot_policy"
    POLICY = { "name" => "daily_8_weekly_40", "daily_threshold_hours" => "8.0", "weekly_threshold_hours" => "40.0",
      "workweek_start" => "sunday", "time_zone" => "Pacific/Guam", "allocator_commit" => "6f72a984",
      "effective_from" => "2026-04-01", "effective_before" => "2026-10-16" }.freeze

    def initialize(source:, inventory:)
      @source, @inventory = source, inventory
      @cache = {}
    end

    def call(batch:, employee:)
      key = [ batch["batch_id"], employee["source_user_id"] ]
      return @cache[key] if @cache.key?(key)

      @cache[key] = verify(batch: batch, employee: employee)
    end

    private

    def verify(batch:, employee:)
      proof = batch.dig("export", "prior_overtime_policy")
      return unless proof.is_a?(Hash) && @inventory && Date.iso8601(batch.fetch("start_date")) >= Date.new(2026, 4, 1) &&
        Date.iso8601(batch.fetch("end_date")) < Date.new(2026, 10, 16) &&
        proof["kind"] == KIND && proof["policy"] == POLICY && proof["source_instance_id"] == @source.expected_source_instance_id &&
        proof["input_scope"] == "all_effective_frozen_current_lines_in_workweek_through_batch_end" &&
        proof["batch_id"] == batch.fetch("batch_id") && proof["batch_checksum"] == batch.dig("export", "checksum") &&
        proof["evidence_checksum"] == CanonicalPayload.checksum(proof.except("evidence_checksum")) &&
        proof.dig("threshold_evidence", "basis") == "owner_reviewed_8_40_fallback_no_versioned_setting_history"

      row = proof.fetch("employees").find { |candidate| candidate["source_user_id"] == employee.fetch("source_user_id") }
      return unless row && row["eligible"] == true && row["blockers"] == [] &&
        row["source_user_uuid"].present? && row["inputs_checksum"] == CanonicalPayload.checksum(row.fetch("inputs"))
      return unless row.fetch("inputs").all? do |input|
        current = @inventory[input.fetch("source_time_entry_id")]
        current && current.fetch("version") == input.fetch("version") && current.fetch("source_user_uuid") == row["source_user_uuid"] &&
          input["source_user_uuid"] == row["source_user_uuid"] && input["source_user_id"] == current.dig("employee", "id") &&
          current.dig("employee", "id") == row["source_user_id"] && decimal(current.fetch("hours")) == decimal(input.fetch("hours")) &&
          current.fetch("work_date") == input.fetch("work_date") &&
          current.dig("history_evidence", "payable_content_checksum") == input.fetch("payable_content_checksum") &&
          input.fetch("frozen_rows").all? do |reference|
            Array(current.dig("history_evidence", "baseline_lines")).any? do |line|
              reference.all? { |key, value| line[key] == value } &&
                (line["current_content_matches"] == true || line.dig("legacy_frozen_evidence", "eligible") == true)
            end
          end
      end
      inputs = row.fetch("inputs")
      return unless inputs.any? && inputs.map { |input| input.fetch("source_time_entry_id") }.uniq.length == inputs.length

      allocations = row.fetch("allocations")
      keys = allocations.map { |line| line.values_at("source_time_entry_id", "line_key") }
      original = employee.fetch("adjustments")
      return unless keys.uniq.length == keys.length && keys.sort == original.map { |line| line.values_at("source_time_entry_id", "line_key") }.sort

      changed = false
      comparison = employee.deep_dup
      comparison["adjustments"] = original.map do |line|
        allocation = allocations.find { |candidate| candidate.values_at("source_time_entry_id", "line_key") == line.values_at("source_time_entry_id", "line_key") }
        return unless decimal(allocation.fetch("regular_hours")) + decimal(allocation.fetch("overtime_hours")) == decimal(line.fetch("total_hours"))

        changed ||= %w[regular_hours overtime_hours].any? { |key| decimal(line.fetch(key)) != decimal(allocation.fetch(key)) }
        line.merge(allocation.slice("regular_hours", "overtime_hours"))
      end
      return unless changed # Unchanged historical splits retain their original baseline class.

      evidence = { "type" => KIND, "policy" => proof.fetch("policy"), "threshold_evidence" => proof.fetch("threshold_evidence"),
        "batch_id" => batch.fetch("batch_id"), "batch_checksum" => batch.dig("export", "checksum"),
        "evidence_checksum" => proof.fetch("evidence_checksum"), "inputs_checksum" => row.fetch("inputs_checksum"),
        "source_user_id" => row.fetch("source_user_id"), "source_user_uuid" => row.fetch("source_user_uuid"),
        "frozen_split" => split(original), "prior_policy_split" => split(comparison.fetch("adjustments")) }
      { employee: comparison, evidence: evidence }
    rescue KeyError, ArgumentError, TypeError, NoMethodError
      nil
    end

    def split(lines)
      %w[regular_hours overtime_hours].index_with { |key| lines.sum { |line| decimal(line.fetch(key)) }.to_s("F") }
    end

    def decimal(value)
      number = BigDecimal(value.to_s)
      raise ArgumentError unless number.finite? && number >= 0

      number
    end
  end
end
