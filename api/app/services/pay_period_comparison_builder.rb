# frozen_string_literal: true

class PayPeriodComparisonBuilder
  MONEY_FIELDS = {
    gross_pay: :gross_pay,
    net_pay: :net_pay,
    fit: :withholding_tax,
    social_security: :social_security_tax,
    medicare: :medicare_tax,
    total_deductions: :total_deductions,
    reported_tips: :reported_tips,
    tips_paid_out: :tips_paid_out,
    loan_deduction: :loan_deduction,
    loan_payment: :loan_payment
  }.freeze

  OUTLIER_THRESHOLD_DOLLARS = BigDecimal("100.00")
  OUTLIER_THRESHOLD_PERCENT = BigDecimal("0.20")

  def initialize(pay_period)
    @pay_period = pay_period
    @previous_period = previous_period
  end

  def call
    current_items = comparison_items(@pay_period)
    previous_items = @previous_period ? comparison_items(@previous_period) : []
    employee_changes = @previous_period ? employee_changes_payload(current_items, previous_items) : []

    {
      current_pay_period: period_payload(@pay_period),
      previous_pay_period: @previous_period ? period_payload(@previous_period) : nil,
      summary: summary_payload(current_items, previous_items),
      employee_changes: employee_changes,
      review_flags: review_flags_payload(employee_changes)
    }
  end

  private

  def previous_period
    PayPeriod
      .reportable_committed
      .regular_cycle
      .where(company_id: @pay_period.company_id)
      .where.not(id: @pay_period.id)
      .where("pay_date < ? OR (pay_date = ? AND id < ?)", @pay_period.pay_date, @pay_period.pay_date, @pay_period.id)
      .order(pay_date: :desc, id: :desc)
      .first
  end

  def period_payload(period)
    {
      id: period.id,
      start_date: period.start_date,
      end_date: period.end_date,
      pay_date: period.pay_date,
      status: period.status,
      period_description: period.period_description
    }
  end

  def comparison_items(period)
    period.payroll_items
      .not_voided
      .includes(employee: :department)
      .to_a
  end

  def summary_payload(current_items, previous_items)
    current = aggregate_items(current_items)
    previous = aggregate_items(previous_items)

    keys = [ :employee_count, *MONEY_FIELDS.keys ]
    keys.index_with do |key|
      current_value = current.fetch(key, 0)
      previous_value = previous.fetch(key, 0)
      {
        current: numeric_payload(current_value),
        previous: numeric_payload(previous_value),
        delta: numeric_payload(current_value - previous_value),
        percent_delta: percent_delta(current_value, previous_value)
      }
    end
  end

  def aggregate_items(items)
    totals = { employee_count: items.map(&:employee_id).uniq.size }
    MONEY_FIELDS.each do |key, field|
      totals[key] = items.sum { |item| decimal(item.public_send(field)) }
    end
    totals
  end

  def employee_changes_payload(current_items, previous_items)
    current_by_employee = current_items.index_by(&:employee_id)
    previous_by_employee = previous_items.index_by(&:employee_id)
    employee_ids = (current_by_employee.keys + previous_by_employee.keys).uniq

    employee_ids.filter_map do |employee_id|
      current_item = current_by_employee[employee_id]
      previous_item = previous_by_employee[employee_id]
      employee = current_item&.employee || previous_item&.employee
      change_type = if current_item && previous_item
        "changed"
      elsif current_item
        "new"
      else
        "missing"
      end

      deltas = employee_delta_payload(current_item, previous_item)
      flags = employee_flags(employee, current_item, previous_item, deltas, change_type)
      next if change_type == "changed" && flags.empty?

      {
        employee_id: employee_id,
        employee_name: employee&.full_name || current_item&.employee_full_name || previous_item&.employee_full_name,
        department_name: employee&.department&.name,
        employment_type: current_item&.employment_type || previous_item&.employment_type,
        salary_type: employee&.salary_type,
        change_type: change_type,
        flags: flags,
        current: current_item ? employee_snapshot(current_item) : nil,
        previous: previous_item ? employee_snapshot(previous_item) : nil,
        deltas: deltas
      }
    end.sort_by { |row| [ severity_rank(row[:flags]), row[:employee_name].to_s ] }
  end

  def employee_snapshot(item)
    MONEY_FIELDS.keys.index_with do |key|
      numeric_payload(decimal(item.public_send(MONEY_FIELDS.fetch(key))))
    end.merge(
      hours_worked: numeric_payload(decimal(item.hours_worked)),
      salary_override: numeric_payload(decimal(item.salary_override))
    )
  end

  def employee_delta_payload(current_item, previous_item)
    fields = [ :gross_pay, :net_pay, :fit, :reported_tips, :tips_paid_out, :loan_deduction, :loan_payment, :total_deductions ]
    fields.index_with do |key|
      current_value = current_item ? decimal(current_item.public_send(MONEY_FIELDS.fetch(key))) : BigDecimal("0")
      previous_value = previous_item ? decimal(previous_item.public_send(MONEY_FIELDS.fetch(key))) : BigDecimal("0")
      {
        current: numeric_payload(current_value),
        previous: numeric_payload(previous_value),
        delta: numeric_payload(current_value - previous_value),
        percent_delta: percent_delta(current_value, previous_value)
      }
    end
  end

  def employee_flags(employee, current_item, previous_item, deltas, change_type)
    flags = []
    flags << flag("new_employee", "Employee is included this period but was not in the previous committed period.", "review") if change_type == "new"
    flags << flag("missing_employee", "Employee was in the previous committed period but is missing from this period.", "warning") if change_type == "missing"

    if current_item && previous_item
      [
        [ :gross_pay, "Gross pay changed materially" ],
        [ :net_pay, "Net pay changed materially" ],
        [ :reported_tips, "Reported tips changed materially" ],
        [ :loan_deduction, "Loan deduction changed materially" ],
        [ :loan_payment, "Loan payment changed materially" ],
        [ :total_deductions, "Total deductions changed materially" ]
      ].each do |key, message|
        flags << flag(key.to_s, message, "review") if material_delta?(deltas.dig(key, :delta), deltas.dig(key, :previous))
      end
    end

    if employee&.variable_salary? && current_item
      if decimal(current_item.salary_override) <= 0
        flags << flag("variable_salary_missing", "Variable salary employee has no positive period pay entered.", "warning")
      elsif previous_item && decimal(current_item.salary_override) != decimal(previous_item.salary_override)
        flags << flag("variable_salary_changed", "Variable salary period pay changed from the previous committed period.", "review")
      end
    end

    flags
      .uniq { |entry| entry[:key] }
      .sort_by { |entry| severity_rank([ entry ]) }
  end

  def review_flags_payload(employee_changes)
    if @previous_period.nil?
      return {
        status: "ok",
        warning_count: 0,
        review_count: 0,
        message: "No previous committed pay period found for comparison."
      }
    end

    warnings = employee_changes.sum { |row| row[:flags].count { |flag| flag[:severity] == "warning" } }
    reviews = employee_changes.sum { |row| row[:flags].count { |flag| flag[:severity] == "review" } }

    {
      status: warnings.positive? ? "warning" : reviews.positive? ? "review" : "ok",
      warning_count: warnings,
      review_count: reviews,
      message: if warnings.positive?
        "Review required before approval."
      elsif reviews.positive?
        "Review recommended before approval."
      else
        "No material period-to-period changes detected."
      end
    }
  end

  def material_delta?(delta_number, previous_number)
    delta = decimal(delta_number).abs
    previous = decimal(previous_number).abs
    return false if delta < OUTLIER_THRESHOLD_DOLLARS
    return true if previous.zero?

    (delta / previous) >= OUTLIER_THRESHOLD_PERCENT
  end

  def flag(key, message, severity)
    { key: key, message: message, severity: severity }
  end

  def percent_delta(current_value, previous_value)
    previous = decimal(previous_value)
    return nil if previous.zero?

    (((decimal(current_value) - previous) / previous) * 100).round(2).to_f
  end

  def numeric_payload(value)
    decimal(value).round(2).to_f
  end

  def decimal(value)
    BigDecimal(value.to_s.presence || "0")
  rescue ArgumentError
    BigDecimal("0")
  end

  def severity_rank(flags)
    return 0 if flags.any? { |flag| flag[:severity] == "warning" }
    return 1 if flags.any? { |flag| flag[:severity] == "review" }

    2
  end
end
