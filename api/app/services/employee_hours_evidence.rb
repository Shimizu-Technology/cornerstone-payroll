# frozen_string_literal: true

# Only mapped, permanently identified producers can supply employee evidence.
# Local saved payroll remains independently available when a source is offline.
class EmployeeHoursEvidence
  def initialize(employee:, actor:, params: {})
    @employee = employee
    @actor = actor
    @params = params.symbolize_keys
  end

  def call
    validate_filters!
    mappings = TimeTrackingEmployeeMapping.where(company_id: @employee.company_id, employee_id: @employee.id)
      .joins(:time_tracking_source).where(time_tracking_sources: { company_id: @employee.company_id })
      .includes(:time_tracking_source).order(:id).to_a
    selected = if @params[:source_id].present?
      mappings.find { |row| row.time_tracking_source_id.to_s == @params[:source_id].to_s } || raise(ActiveRecord::RecordNotFound)
    else
      mappings.reverse.find { |row| row.time_tracking_source.active? } || mappings.last
    end
    @source = selected&.time_tracking_source
    result = { sources: mappings.map { |row| source_metadata(row) }, source_id: @source&.id }
    return result.merge(status: "not_linked", message: "No time tracking employee link is recorded. Salary and other workers may not track time.") unless selected
    return result.merge(status: "unavailable", message: "This connection is disabled. Saved payroll history remains available.") unless @source.active?
    unless @source.remote_identity_pinned? && selected.source_user_uuid.present?
      return result.merge(status: "unavailable", message: "Verify the connection and permanent employee identity before reviewing source hours.")
    end
    unless @source.respond_to?(:supports?) && @source.supports?(:employee_period_evidence_v1)
      return result.merge(status: "unsupported", message: "This time tracking connection does not provide employee period evidence.")
    end

    client = TimeTracking::Client.for_payroll_actor(@source, actor: @actor)
    payload = if @params[:period_id].present?
      client.payroll_employee_period(employee_id: selected.source_user_id, period_id: @params[:period_id], source_user_uuid: selected.source_user_uuid,
        start_date: @params[:start_date].presence, end_date: @params[:end_date].presence,
        detail_per_page: @params[:detail_per_page].presence || 100, detail_cursor: @params[:detail_cursor].presence)
    else
      client.payroll_employee_periods(employee_id: selected.source_user_id, source_user_uuid: selected.source_user_uuid,
        start_date: @params[:start_date].presence, end_date: @params[:end_date].presence,
        cursor: @params[:cursor].presence, per_page: @params[:per_page].presence || 20)
    end
    validate_payload!(payload)
    if payload.dig("period", "entries").is_a?(Array)
      payload["period"]["entries"].each { |entry| entry["source_entry_url"] = workspace_url(selected, entry_id: entry["id"]) }
    end
    result.merge(status: "available", evidence: payload, source_workspace_url: workspace_url(selected),
      payroll_records: linked_payroll_records(payload))
  rescue TimeTracking::Client::Error => error
    result.merge(status: "unavailable", message: error.message)
  end

  private

  def validate_filters!
    %i[start_date end_date period_id].each do |key|
      next if @params[key].blank?
      raise ArgumentError, "#{key} must use YYYY-MM-DD" unless @params[key].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.iso8601(@params[key].to_s)
    end
    if @params[:start_date].present? && @params[:end_date].present? && @params[:start_date] > @params[:end_date]
      raise ArgumentError, "End date must be on or after start date"
    end
    limit = Integer(@params[:per_page].presence || 20, exception: false)
    raise ArgumentError, "per_page must be between 1 and 100" unless limit&.between?(1, 100)
    detail_limit = Integer(@params[:detail_per_page].presence || 100, exception: false)
    raise ArgumentError, "detail_per_page must be between 1 and 100" unless detail_limit&.between?(1, 100)
    raise ArgumentError, "Cursor is too long" if @params[:cursor].to_s.bytesize > 4096 || @params[:detail_cursor].to_s.bytesize > 4096
  end

  def validate_payload!(payload)
    unless payload.is_a?(Hash)
      raise TimeTracking::Client::Error, "The source returned incomplete employee period evidence. Please retry."
    end

    if @params[:period_id].present?
      period = payload["period"]
      valid = period.is_a?(Hash) && period["id"] == @params[:period_id] && period["summary"].is_a?(Hash) &&
        %w[entries coverage_lines settlement_cases].all? do |key|
          period[key].is_a?(Array) && period[key].all? { |row| row.is_a?(Hash) }
        end
    else
      valid = payload["periods"].is_a?(Array) && payload["totals"].is_a?(Hash) && payload["pagination"].is_a?(Hash) &&
        payload["pagination"]["total_count"].is_a?(Integer) && payload["pagination"]["total_count"] >= 0 &&
        payload["periods"].all? { |period| period.is_a?(Hash) && valid_work_period_id?(period["id"]) && period["summary"].is_a?(Hash) }
    end
    raise TimeTracking::Client::Error, "The source returned incomplete employee period evidence. Please retry." unless valid
  end

  # Compatible producers identify an original work period by its start date.
  def valid_work_period_id?(value)
    return false unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value)
    true
  rescue Date::Error
    false
  end

  def source_metadata(mapping)
    { id: mapping.time_tracking_source_id, name: mapping.time_tracking_source.name,
      active: mapping.time_tracking_source.active?, employee_identity_verified: mapping.source_user_uuid.present?,
      last_synced_at: mapping.time_tracking_source.last_synced_at }
  end

  def workspace_url(mapping, entry_id: nil)
    path = @source.connector.employee_evidence_path(employee_id: mapping.source_user_id, period_id: @params[:period_id].presence, entry_id: entry_id)
    origin = @source.connector.authorization_origins.first
    return if path.blank? || origin.blank? || !path.start_with?("/") || path.start_with?("//")

    url = URI.join("#{origin}/", path)
    approved = URI.parse(origin)
    return unless url.scheme == "https" && url.host == approved.host && url.port == approved.port && url.userinfo.nil?

    query = URI.decode_www_form(url.query.to_s)
    query.concat([ [ "source_user_uuid", mapping.source_user_uuid ], [ "source_instance_id", @source.expected_source_instance_id ] ])
    %i[start_date end_date].each { |key| query << [ key.to_s, @params[key] ] if @params[key].present? }
    url.query = URI.encode_www_form(query)
    url.to_s
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  def linked_payroll_records(payload)
    lines = payload.dig("period", "coverage_lines") || []
    references = lines.filter_map do |line|
      item_id = line["external_payroll_item_id"].to_s
      period_id = line["external_pay_period_id"].to_s
      [ item_id, period_id ] if item_id.match?(/\A[1-9]\d*\z/) && period_id.match?(/\A[1-9]\d*\z/)
    end.uniq
    return [] if references.empty?

    PayrollItem.where(company_id: @employee.company_id, employee_id: @employee.id, id: references.map(&:first))
      .includes(:pay_period, :check_events, :direct_deposit_payment_confirmation).filter_map do |item|
        next unless references.include?([ item.id.to_s, item.pay_period_id.to_s ])

        { payroll_item_id: item.id, pay_period_id: item.pay_period_id, check_number: item.check_number,
          pay_date: item.pay_period.pay_date, period_description: item.pay_period.period_description,
          pay_period_status: item.pay_period.status,
          regular_hours: item.hours_worked&.to_f, overtime_hours: item.overtime_hours&.to_f,
          holiday_hours: item.holiday_hours&.to_f, pto_hours: item.pto_hours&.to_f,
          gross_pay: item.gross_pay&.to_f, net_pay: item.net_pay&.to_f,
          payment_evidence: EmployeePayrollPaymentEvidence.new(item).call }
      end
  end
end
