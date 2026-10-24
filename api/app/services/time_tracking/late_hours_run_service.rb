# frozen_string_literal: true

module TimeTracking
  class LateHoursRunService
    class Error < StandardError; end

    def initialize(pay_period:, source:, actor:)
      @origin = pay_period
      @source = source
      @actor = actor
    end

    def review
      validate_source!
      payload = client.payroll_cockpit_late_hours(external_pay_period_id: external_id)
      payload.merge("cases" => Array(payload["cases"]).map { |row| payroll_case(row) },
        "runs" => runs.order(:id).map { |run| present(run) },
        "can_pay" => allowed?)
    rescue Client::Error => e
      { "cases" => [], "period_version" => nil, "runs" => runs.order(:id).map { |run| present(run) },
        "can_pay" => allowed?, "source_error" => e.message }
    end

    def create!(command_id:, cases:, pay_date:, expected_version:)
      authorize!
      request = normalize_request(cases, pay_date, expected_version)
      raise Error, "Use a valid request ID" unless command_id.to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)

      run = source.with_lock do
        authorize!
        existing = source.time_tracking_late_hours_runs.find_by(command_id: command_id)
        if existing
          raise Error, "This request ID already names a different late-hours selection" unless existing.origin_pay_period_id == origin.id && existing.request_payload == request
          next existing
        end
        create_intent!(command_id, request)
      end
      resume!(run)
    rescue Error, Client::Error, ArgumentError, ActiveRecord::RecordInvalid, PayrollGoLiveGate::BlockedError => e
      run&.update!(last_error: e.message)
      raise
    end

    def retry!(id)
      authorize!
      run = runs.find(id)
      resume!(run)
    rescue Error, Client::Error, ArgumentError, ActiveRecord::RecordInvalid, PayrollGoLiveGate::BlockedError => e
      run&.update!(last_error: e.message)
      raise
    end

    def present(run)
      { id: run.id, pay_period_id: run.adjustment_pay_period_id, pay_date: run.adjustment_pay_period.pay_date.iso8601,
        applied: run.applied_at.present?, last_error: run.last_error }
    end

    private

    attr_reader :origin, :source, :actor

    def runs
      TimeTrackingLateHoursRun.where(origin_pay_period: origin, time_tracking_source: source)
    end

    def allowed?
      StaffRolePolicy.allowed?(actor, :manage_client_configuration, company: origin.company)
    end

    def authorize!
      actor.reload
      raise Error, "Client management access is required to pay late hours" unless allowed? && actor.can_access_company?(origin.company_id)
      validate_source!
    end

    def validate_source!
      unless source&.active? && source.company_id == origin.company_id && source.supports?(:finalized_batch_v2) &&
          origin.aire_payroll_calendar_period&.time_tracking_source_id == source.id
        raise Error, "Open the original connected payroll to pay its late hours"
      end
      raise Error, "Complete historical reconciliation before paying new source hours" unless source.historical_reconciliation_complete?
    end

    def external_id
      origin.aire_payroll_calendar_period.external_pay_period_id
    end

    def client
      @client ||= Client.for_payroll_actor(source, actor: actor)
    end

    def normalize_request(cases, pay_date, expected_version)
      selected = Array(cases).map do |row|
        data = row.to_h.stringify_keys
        { "id" => data.fetch("id").to_s, "version" => Integer(data.fetch("version").to_s, 10) }
      end.sort_by { |row| row.fetch("id") }
      unless selected.any? && selected.size <= 250 && selected.map { |row| row["id"] }.uniq.size == selected.size
        raise Error, "Choose each late-hours case once (up to 250)"
      end
      date = Date.iso8601(pay_date.to_s)
      raise Error, "Pay date cannot be before the source work period" if date < origin.end_date
      { "cases" => selected, "pay_date" => date.iso8601, "expected_version" => Integer(expected_version.to_s, 10) }
    rescue KeyError, ArgumentError, TypeError
      raise Error, "Refresh late hours and choose valid cases, versions and pay date"
    end

    def payroll_case(row)
      candidate = row.deep_dup
      uuid = TimeTrackingEmployeeMapping.normalize_uuid(row.dig("employee", "payroll_integration_id"))
      mapping = source.time_tracking_employee_mappings.find_by(source_user_uuid: uuid) if uuid.present?
      employee = mapping&.employee
      reasons = []
      reasons << "Link this AIRE employee to an active Payroll employee first" unless employee&.active? && employee.company_id == origin.company_id
      reasons << "These hours require an hourly payroll employee" if employee && !employee.hourly? && !employee.contractor_hourly?
      rates = employee ? employee.active_wage_rates.reject { |rate| rate.rate.nil? } : []
      lines = Array(row["adjustments"]).map do |line|
        category = line["category"] || {}
        keys = [ category["key"], category["name"] ].compact.map { |label| normalize_label(label) }
        matches = rates.select { |rate| keys.include?(normalize_label(rate.label)) }
        rate = matches.one? ? matches.first : nil
        reasons << "Set up one matching Payroll earning type for #{category['name'] || 'this category'}" unless rate
        line.merge("payroll_rate" => rate&.rate&.to_f, "employee_wage_rate_id" => rate&.id)
      end
      reasons << "No approved positive source hours are available" if lines.empty? || lines.any? { |line| BigDecimal(line.fetch("total_hours").to_s) <= 0 }
      candidate.merge("adjustments" => lines, "payroll_employee_id" => employee&.id,
        "payroll_employment_type" => employee&.employment_type, "payroll_contractor_pay_type" => employee&.contractor_pay_type,
        "blocked_reason" => reasons.uniq.presence&.join(". "))
    end

    def normalize_label(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
    end

    def create_intent!(command_id, request)
      payload = review
      raise Error, "The source period changed. Refresh late hours" unless payload["period_version"] == request["expected_version"]
      available = payload.fetch("cases").index_by { |row| row.fetch("id") }
      selected = request.fetch("cases").map do |selection|
        row = available[selection.fetch("id")]
        raise Error, "These hours are no longer available. Refresh late hours" unless row
        raise Error, "These hours changed. Refresh late hours" unless row.fetch("version") == selection.fetch("version")
        raise Error, row.fetch("blocked_reason") if row["blocked_reason"].present?
        row
      end
      rate_ids = selected.flat_map { |row| row.fetch("adjustments").pluck("employee_wage_rate_id") }.uniq
      captured_rates = EmployeeWageRate.where(id: rate_ids).lock.map(&:attributes)
      workweek = origin.resolved_company_workweek
      raise Error, "Confirm the legal workweek before paying late hours" unless workweek&.confirmed?
      PayrollGoLiveGate.new(company: origin.company, pay_date: request.fetch("pay_date")).require_live_payroll!(parallel_run: false)
      adjustment = PayPeriod.create!(company: origin.company, company_workweek: workweek,
        start_date: origin.start_date, end_date: origin.end_date, pay_date: request.fetch("pay_date"),
        run_purpose: "adjustment", run_purpose_source: "operator_selected", status: "draft",
        includes_base_salary: false, includes_recurring_items: false)
      TimeTrackingLateHoursRun.create!(company: origin.company, time_tracking_source: source,
        origin_pay_period: origin, adjustment_pay_period: adjustment, created_by: actor,
        command_id: command_id, request_payload: request, rate_snapshot: captured_rates, selection_snapshot: selected)
    end

    def verify_selection!(run)
      expected = run.selection_snapshot.flat_map do |row|
        row.fetch("adjustments").map { |line| line_identity(line, row.dig("employee", "payroll_integration_id")) }
      end.sort_by(&:to_s)
      actual = Array(run.batch_payload["employees"]).flat_map do |employee|
        Array(employee["adjustments"]).map { |line| line_identity(line, employee["source_user_uuid"]) }
      end.sort_by(&:to_s)
      raise Error, "The source returned different hours than the selected cases. Review the saved adjustment" unless expected == actual
    end

    def line_identity(line, uuid)
      [ uuid.to_s.downcase, *line.values_at("source_time_entry_id", "source_time_entry_version", "line_key", "original_work_date", "source_category_id"),
        *line.values_at("regular_hours", "overtime_hours").map { |value| BigDecimal(value.to_s) } ]
    end

    def validate_payroll_setup!(run)
      run.selection_snapshot.each do |row|
        employee = Employee.lock.find_by(id: row.fetch("payroll_employee_id"), company_id: origin.company_id)
        mapping = source.time_tracking_employee_mappings.find_by(source_user_uuid: row.dig("employee", "payroll_integration_id"))
        unless employee&.active? && mapping&.employee_id == employee.id &&
            employee.employment_type == row.fetch("payroll_employment_type") &&
            employee.contractor_pay_type == row["payroll_contractor_pay_type"]
          raise Error, "The selected employee's mapping or pay basis changed. Review the saved late-hours adjustment before resuming"
        end
      end
    end

    def resume!(run)
      run.with_lock do
        authorize!
        return run if run.applied_at
        unless run.adjustment_pay_period.draft? && run.adjustment_pay_period.payroll_items.empty?
          raise Error, "The late-hours adjustment changed before import. Review it before retrying"
        end
        if run.batch_payload.blank?
          response = client.create_payroll_late_hours(external_pay_period_id: external_id,
            command_id: run.command_id, expected_version: run.request_payload.fetch("expected_version"),
            reason: "Pay approved late hours in Cornerstone adjustment #{run.adjustment_pay_period_id}",
            target_external_pay_period_id: run.adjustment_pay_period_id.to_s,
            pay_date: run.request_payload.fetch("pay_date"), cases: run.request_payload.fetch("cases"))
          raise Error, "AIRE did not return the saved supplemental batch. Resume this adjustment" unless response.is_a?(Hash) && response["payroll_batch"].is_a?(Hash)
          run.update!(batch_payload: response.fetch("payroll_batch"))
        end
        verify_selection!(run)
        validate_payroll_setup!(run)
        authorize!
        import = BatchImportPreviewService.new(pay_period: run.adjustment_pay_period, source: source,
          supplemental_payload: run.batch_payload).call
        result = ApplyImportService.new(import: import, mappings: [], applied_by: actor).call
        raise Error, result.fetch(:errors).map { |error| error.fetch(:error) }.join(". ") if result.fetch(:errors).any?
        run.update!(applied_at: Time.current, last_error: nil)
      end
      run
    end
  end
end
