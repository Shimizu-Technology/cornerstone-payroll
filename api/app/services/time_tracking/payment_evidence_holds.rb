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
      prime_period_attestations! if @source.supports?(:payment_attestation_resolution_v1)
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
      holds = mappings.keys.flat_map { |uuid| attestations_for(uuid) }.select { |hold| in_period?(hold["work_date"]) }
        .map { |hold| hold.merge("employee_name" => mappings.fetch(hold["source_user_uuid"]).employee.full_name) }
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
      if TimeTrackingManualAllocation.pending_payment_resolution.exists?(time_tracking_source: @source,
        source_payment_attestation_id: attestation_id.to_s)
        conflict!("Reconcile the saved reported-payment match before withdrawing this report")
      end
      # A source edit must not prevent a reasoned retraction. The frozen hold identity
      # scopes the command; AIRE serializes it against finalization and routes review.
      @client.retract_payroll_payment_attestation(attestation_id: attestation_id,
        command_id: command_id, expected_version: expected_version, reason: reason)
    end

    private

    # The verified resolution contract supports a period-scoped list without an
    # employee filter. Include held-only workers as well as ordinary candidates;
    # reading only the manual review's positive rows would hide those holds.
    def prime_period_attestations!
      return if @period_attestations_loaded
      @attestations = mappings.keys.index_with { [] }
      1.upto(10) do |page|
        payload = @client.payroll_payment_attestations(page: page,
          start_date: @pay_period.start_date.iso8601, end_date: @pay_period.end_date.iso8601)
        payload.fetch("payment_attestations").each do |row|
          next unless mappings.key?(row["source_user_uuid"]) && in_period?(row["work_date"])
          @attestations.fetch(row["source_user_uuid"]) << row
        end
        total_pages = Integer(payload.fetch("pagination").fetch("total_pages"))
        break if page >= total_pages
        conflict!("Payment evidence history is too large for this view; review it with your administrator") if page == 10
      end
      @period_attestations_loaded = true
    end

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
          query = { source_user_uuid: uuid, page: page }
          if @source.supports?(:payment_attestation_resolution_v1)
            query.merge!(start_date: @pay_period.start_date.iso8601, end_date: @pay_period.end_date.iso8601)
          end
          payload = @client.payroll_payment_attestations(**query)
          rows = payload.fetch("payment_attestations")
          # A producer response cannot assign another employee's holds to this query.
          accumulated.concat(rows.select { |row| row["source_user_uuid"] == uuid })
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
