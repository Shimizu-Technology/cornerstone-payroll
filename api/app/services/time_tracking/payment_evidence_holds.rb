# frozen_string_literal: true

module TimeTracking
  # Reported payment only suspends source hours; it never verifies a check or pays payroll.
  class PaymentEvidenceHolds
    def initialize(pay_period:, source:, client:)
      @pay_period, @source, @client = pay_period, source, client
    end

    def review
      payload = @client.payroll_cockpit_manual_review(start_date: @pay_period.start_date.iso8601,
        end_date: @pay_period.end_date.iso8601, external_pay_period_id: @pay_period.id)
      candidates = payload.fetch("employees", []).flat_map do |employee|
        mapping = mappings[employee["source_user_uuid"] || employee["payroll_integration_id"]]
        next [] unless mapping

        existing_hold_entry_ids = attestations_for(mapping.source_user_uuid).map { |hold| hold["source_time_entry_id"].to_s }
        allocated_entry_ids = payload.fetch("manual_allocations", []).reject { |allocation| allocation["status"] == "voided" }
          .map { |allocation| allocation["source_time_entry_id"].to_s }
        employee.fetch("adjustments", []).filter_map do |entry|
          next if existing_hold_entry_ids.include?(entry["source_time_entry_id"].to_s) ||
            allocated_entry_ids.include?(entry["source_time_entry_id"].to_s) || entry["source_kind"] != "current"
          next unless in_period?(entry["original_work_date"]) && entry["total_hours"].to_f.positive? &&
            entry["source_time_entry_version"].is_a?(Integer)

          entry.slice("source_time_entry_id", "source_time_entry_version", "original_work_date", "total_hours")
            .merge("source_user_uuid" => mapping.source_user_uuid, "employee_name" => mapping.employee.full_name)
        end
      end
      holds = payload.fetch("payment_attestations", []).filter_map do |hold|
        next unless mappings[hold["source_user_uuid"]] && in_period?(hold["original_work_date"])

        find_attestation!(hold.fetch("id"), hold.fetch("source_user_uuid"))
      end
      { candidates: candidates.uniq { |entry| entry.fetch("source_time_entry_id") }, payment_attestations: holds }
    end

    def create!(source_time_entry_id:, source_user_uuid:, command_id:, expected_version:, reason:)
      validate_reason!(reason)
      mapping = mapping!(source_user_uuid)
      entry = @client.payroll_cockpit_time_entry(entry_id: source_time_entry_id).fetch("time_entry")
      unless entry["id"].to_s == source_time_entry_id.to_s &&
          entry.dig("employee", "id").to_s == mapping.source_user_id.to_s &&
          entry.dig("employee", "payroll_integration_id") == mapping.source_user_uuid && in_period?(entry["work_date"])
        conflict!("AIRE source identity or work date changed. Refresh and review the exact entry before recording a hold.")
      end
      @client.create_payroll_payment_attestation(source_time_entry_id: source_time_entry_id,
        source_user_uuid: mapping.source_user_uuid, command_id: command_id, expected_version: expected_version, reason: reason)
    end

    def retract!(attestation_id:, source_user_uuid:, command_id:, expected_version:, reason:)
      validate_reason!(reason)
      mapping!(source_user_uuid)
      hold = find_attestation!(attestation_id, source_user_uuid)
      conflict!("This payment hold belongs to a different work period") unless in_period?(hold["work_date"])
      # A source edit must not prevent a reasoned retraction. The frozen hold identity
      # scopes the command; AIRE serializes it against finalization and routes review.
      @client.retract_payroll_payment_attestation(attestation_id: attestation_id,
        command_id: command_id, expected_version: expected_version, reason: reason)
    end

    private

    def mappings
      @mappings ||= @source.time_tracking_employee_mappings.includes(:employee)
        .where(company_id: @pay_period.company_id).where.not(source_user_uuid: nil)
        .select { |mapping| mapping.employee.company_id == @pay_period.company_id }
        .index_by(&:source_user_uuid)
    end

    def mapping!(uuid)
      mappings[uuid.to_s] || conflict!("Confirm this employee's permanent AIRE identity for this company before managing payment evidence")
    end

    def find_attestation!(id, uuid)
      attestations_for(uuid).find { |record| record["id"].to_s == id.to_s && record["source_user_uuid"] == uuid } ||
        conflict!("Payment evidence identity changed. Refresh the source before retrying.")
    end

    def attestations_for(uuid)
      @attestations ||= {}
      @attestations[uuid] ||= begin
        accumulated = []
        1.upto(10) do |page|
          payload = @client.payroll_payment_attestations(source_user_uuid: uuid, page: page)
          rows = payload.fetch("payment_attestations")
          accumulated.concat(rows)
          total_pages = Integer(payload.fetch("pagination").fetch("total_pages"))
          break if page >= total_pages
          conflict!("Payment evidence history is too large for this view; review it with your administrator") if page == 10
        end
        accumulated
      end
    end

    def in_period?(value)
      (@pay_period.start_date..@pay_period.end_date).cover?(Date.iso8601(value.to_s))
    rescue ArgumentError
      false
    end

    def validate_reason!(reason)
      raise ArgumentError, "Describe the reporter and evidence or retraction reason in at least 20 characters" if reason.to_s.strip.length < 20
    end

    def conflict!(message)
      raise Client::Error.new(message, response_status: 409)
    end
  end
end
