# frozen_string_literal: true

class CheckRegisterService
  def initialize(company:, from:, to:, status: nil)
    @company = company
    @from = Date.iso8601(from.to_s)
    @to = Date.iso8601(to.to_s)
    @status = status.to_s.presence
    raise ArgumentError, "End date must be on or after start date" if @to < @from
    if @status && !CheckReconciliationStatus::STATUSES.include?(@status)
      raise ArgumentError, "Check status is invalid"
    end
  rescue Date::Error
    raise ArgumentError, "Use valid start and end dates"
  end

  def call
    rows = employee_rows + non_employee_rows
    rows.select! { |row| row[:status] == status } if status
    rows.sort_by! { |row| [ row[:register_date], row[:check_number].to_i, row[:source_type], row[:source_id] ] }

    {
      from: from,
      to: to,
      rows: rows,
      summary: summary(rows)
    }
  end

  private

  attr_reader :company, :from, :to, :status

  def employee_rows
    PayrollItem
      .joins(:pay_period)
      .where(company_id: company.id)
      .where.not(check_number: [ nil, "" ])
      .where(pay_periods: { pay_date: from..to })
      .includes(:employee, :pay_period, { check_events: :user }, { check_reconciliation_events: :recorded_by })
      .filter_map { |item| build_employee_row(item) }
  end

  def non_employee_rows
    NonEmployeeCheck
      .where(company_id: company.id, payment_method: "check")
      .where.not(id: NonEmployeeCheckSupersession.select(:non_employee_check_id))
      .where.not(check_number: [ nil, "" ])
      .where(<<~SQL.squish, from, to)
        COALESCE(
          payment_date,
          (created_at AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific/Guam')::date
        ) BETWEEN ? AND ?
      SQL
      .includes(:pay_period, :paid_by, { check_reconciliation_events: :recorded_by })
      .map { |check| build_non_employee_row(check) }
  end

  def build_employee_row(item)
    return if item.net_pay.to_d <= 0

    issued_event = item.check_events
      .select { |event| event.event_type == "delivered" && event.check_number == item.check_number }
      .max_by { |event| [ event.created_at, event.id ] }
    build_row(
      source: item,
      source_type: "payroll_item",
      payee: item.employee.full_name,
      amount: item.net_pay,
      register_date: item.pay_period.pay_date,
      issued_on: issued_event&.effective_on,
      issued_by: issued_event&.user&.name,
      issuance_method: issued_event&.evidence_type,
      issuance_reference: issued_event&.evidence_reference,
      previous_check_numbers: item.check_events.map(&:check_number).compact.uniq - [ item.check_number ]
    )
  end

  def build_non_employee_row(check)
    build_row(
      source: check,
      source_type: "non_employee_check",
      payee: check.payable_to,
      amount: check.amount,
      register_date: check.payment_date || check.pay_period&.pay_date || PayrollBusinessClock.date_for(check.created_at),
      issued_on: check.payment_date,
      issued_by: check.paid_by&.name,
      issuance_method: "payment_confirmation",
      issuance_reference: check.confirmation_number,
      previous_check_numbers: []
    )
  end

  def build_row(source:, source_type:, payee:, amount:, register_date:, issued_on:, issued_by:, issuance_method:, issuance_reference:, previous_check_numbers:)
    reconciliation_event = source.check_reconciliation_events
      .select { |event| event.check_number == source.check_number }
      .max_by { |event| [ event.created_at, event.id ] }
    payment_status = CheckReconciliationStatus.for(source)

    {
      source_type: source_type,
      source_id: source.id,
      pay_period_id: source.pay_period_id,
      check_number: source.check_number,
      previous_check_numbers: previous_check_numbers,
      payee: payee,
      amount: amount.to_d.round(2),
      register_date: register_date,
      status: payment_status,
      reconciliation_status: reconciliation_status(payment_status),
      issued_on: issued_on,
      issued_by: issued_by,
      issuance_method: issuance_method,
      issuance_reference: issuance_reference,
      latest_reconciliation_event: reconciliation_event && event_payload(reconciliation_event)
    }
  end

  def event_payload(event)
    {
      id: event.id,
      event_type: event.event_type,
      effective_on: event.effective_on,
      evidence_type: event.evidence_type,
      evidence_reference: event.evidence_reference,
      reason: event.reason,
      recorded_by: event.recorded_by.name,
      created_at: event.created_at
    }
  end

  def reconciliation_status(payment_status)
    return "reconciled" if payment_status.in?(%w[cleared voided])
    return "action_required" if payment_status == "replacement_required"

    "outstanding"
  end

  def summary(rows)
    statuses = rows.group_by { |row| row[:status] }
    {
      count: rows.size,
      amount: rows.sum { |row| row[:amount] },
      reconciled_count: rows.count { |row| row[:reconciliation_status] == "reconciled" },
      outstanding_count: rows.count { |row| row[:reconciliation_status] == "outstanding" },
      action_required_count: rows.count { |row| row[:reconciliation_status] == "action_required" },
      by_status: CheckReconciliationStatus::STATUSES.to_h do |key|
        values = statuses.fetch(key, [])
        [ key, { count: values.size, amount: values.sum { |row| row[:amount] } } ]
      end
    }
  end
end
