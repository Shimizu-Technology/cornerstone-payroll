# frozen_string_literal: true

# Read-only projection over the same payroll facts used by calculation.
class PayrollExpectedEntries
  def initialize(pay_period)
    @period = pay_period
  end

  def payload
    return { fields: [], missing_regulars: [], outstanding: [] } unless @period.regular_cycle? && @period.regular_run?

    fields = PayrollStandingChange.where(company_id: @period.company_id).active.ordered.includes(:employee, :employee_wage_rate).map do |field|
      value = field_value(field)
      resolution = resolutions.find { |row| row.payroll_standing_change_id == field.id && row.employee_id == field.employee_id }
      status = value.to_d.positive? ? "filled" : resolution && field.allow_none? ? "none" : "missing"
      { id: field.id, employee_id: field.employee_id, employee_wage_rate_id: field.employee_wage_rate_id,
        wage_rate: field.employee_wage_rate&.rate, wage_rate_label: field.employee_wage_rate&.label, label: field.display_label, help_text: field.help_text, kind: field.kind, required: field.required?,
        saved_wage_rate_hours: items.select { |item| item.employee_id == field.employee_id }.flat_map(&:wage_rate_hours),
        allow_none: field.allow_none?, availability_error: field.availability_error, status: status, value: value,
        note: resolution&.note }
    end
    regulars = missing_regulars(fields.map { |field| field[:employee_id] })
    outstanding = fields.select { |field| field[:required] && field[:status] == "missing" }.map { |field| field[:label] } +
      regulars.reject { |row| row[:resolved] }.map { |row| row[:label] }
    { fields: fields, missing_regulars: regulars, outstanding: outstanding }
  end

  private

  def items
    @items ||= @period.payroll_items.financially_reportable.to_a
  end

  def resolutions
    @resolutions ||= PayrollEntryResolution.where(pay_period: @period).to_a
  end

  def field_value(field)
    employee_items = items.select { |item| item.employee_id == field.employee_id }
    return employee_items.sum(0.to_d) { |item| item.salary_override.to_d }.to_s("F") if field.kind == "owner_pay"

    employee_items.sum(0.to_d) do |item|
      if item.wage_rate_hours.present?
        Array(item.wage_rate_hours).select { |row| row["employee_wage_rate_id"].to_s == field.employee_wage_rate_id.to_s }
          .sum { |row| %w[regular_hours overtime_hours holiday_hours pto_hours].sum { |key| row[key].to_d } }
      elsif field.employee.active_wage_rates.one? && field.employee.active_wage_rates.first.id == field.employee_wage_rate_id
        item.hours_worked.to_d + item.overtime_hours.to_d + item.holiday_hours.to_d + item.pto_hours.to_d
      else
        0.to_d
      end
    end.to_s("F")
  end

  def missing_regulars(covered)
    company = @period.company
    recent = PayPeriod.where(company_id: company.id, status: "committed", cycle: "regular", run_purpose: "regular",
      correction_status: nil, parallel_run: false).where("pay_date < ?", @period.pay_date)
      .order(pay_date: :desc, id: :desc).limit(company.regular_pay_lookback).pluck(:id)
    counts = PayrollItem.financially_reportable.where(pay_period_id: recent).where("gross_pay > 0")
      .group(:employee_id).having("COUNT(DISTINCT pay_period_id) >= ?", company.regular_pay_threshold).count
    paid = items.select { |item| item.gross_pay.to_d.positive? || item.salary_override.to_d.positive? || (item.hours_worked.to_d + item.overtime_hours.to_d + item.holiday_hours.to_d + item.pto_hours.to_d).positive? }.map(&:employee_id)
    Employee.where(company_id: company.id, status: "active", id: counts.keys).where.not(id: covered + paid)
      .order(:last_name, :first_name).map do |employee|
        resolution = resolutions.find { |row| row.employee_id == employee.id && row.payroll_standing_change_id.nil? }
        { employee_id: employee.id, label: employee.full_name, resolved: resolution.present?, note: resolution&.note }
      end
  end
end
