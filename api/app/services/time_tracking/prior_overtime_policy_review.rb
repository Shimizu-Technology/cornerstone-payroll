# frozen_string_literal: true

module TimeTracking
  # AIRE performs the preserved production calculation. Payroll authenticates
  # its inputs against fresh inventory and keeps every existing baseline fence.
  class PriorOvertimePolicyReview
    KIND = "paid_under_prior_daily_weekly_ot_policy"
    POLICY = { "name" => "daily_8_weekly_40", "daily_threshold_hours" => "8.0", "weekly_threshold_hours" => "40.0",
      "workweek_start" => "sunday", "time_zone" => "Pacific/Guam", "allocator_commit" => "6f72a984",
      "effective_from" => "2026-04-01", "effective_before" => "2026-10-16" }.freeze

    def initialize(source:, inventory:, runs:, batch_loader:, legacy_verifier:)
      @source, @inventory = source, inventory
      @runs, @batch_loader = runs, batch_loader
      @legacy_verifier = legacy_verifier
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
          context_verified?(input, current)
      end
      inputs = row.fetch("inputs")
      return unless inputs.any? && inputs.map { |input| input.fetch("source_time_entry_id") }.uniq.length == inputs.length
      return unless complete_context?(inputs, row.fetch("source_user_id"), batch)

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

    def context_verified?(input, current)
      references = input.fetch("frozen_rows")
      keys = references.map { |reference| reference.values_at("batch_id", "line_key") }
      return false unless keys.any? && keys.uniq.length == keys.length

      lines = references.filter_map do |reference|
        line = Array(current.dig("history_evidence", "baseline_lines")).find { |candidate| reference.all? { |key, value| candidate[key] == value } }
        next unless line && (line["current_content_matches"] == true ||
          (line.dig("legacy_frozen_evidence", "eligible") == true && @legacy_verifier.call(line, current)))

        payload = @batch_loader.call(reference.fetch("batch_id"))
        run = @runs[line.dig("processing", "external_pay_period_id").to_s]
        next unless run && line.dig("processing", "status") == "committed" && line.dig("processing", "external_system") == "cornerstone_payroll_manual" &&
          line["processing_conflict"] == false && payload.dig("export", "checksum") == reference.fetch("batch_checksum") &&
          run.start_date.iso8601 == payload.fetch("start_date") && run.end_date.iso8601 == payload.fetch("end_date")

        employee = payload.fetch("employees").find { |record| record["source_user_id"] == input.fetch("source_user_id") }
        next unless employee && (employee["source_user_uuid"].blank? || employee["source_user_uuid"] == input.fetch("source_user_uuid"))

        frozen = employee.fetch("adjustments").find do |record|
          record["source_time_entry_id"] == input.fetch("source_time_entry_id") && record["line_key"] == reference.fetch("line_key")
        end
        next unless frozen && frozen["source_kind"] == "current" && frozen["source_time_entry_version"] == line["source_time_entry_version"] &&
          frozen["category"] == line["category"] && frozen["original_work_date"] == line["work_date"] &&
          %w[total_hours regular_hours overtime_hours].all? { |key| decimal(frozen.fetch(key)) == decimal(line.fetch(key)) }

        line
      end
      lines.length == references.length && lines.sum { |line| decimal(line.fetch("total_hours")) } == decimal(input.fetch("hours"))
    end

    def complete_context?(inputs, owner, batch)
      first = Date.iso8601(batch.fetch("start_date")).beginning_of_week(:sunday)
      last = Date.iso8601(batch.fetch("end_date"))
      expected = @inventory.values.flat_map do |current|
        Array(current.dig("history_evidence", "baseline_lines")).filter_map do |line|
          next unless line["source_user_id"] == owner && Date.iso8601(line.fetch("work_date")).between?(first, last)

          [ current.fetch("id"), line.fetch("batch_id"), line.fetch("line_key") ]
        end
      end
      supplied = inputs.flat_map do |input|
        input.fetch("frozen_rows").map { |reference| [ input.fetch("source_time_entry_id"), reference.fetch("batch_id"), reference.fetch("line_key") ] }
      end
      supplied.uniq.length == supplied.length && supplied.sort == expected.sort
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
