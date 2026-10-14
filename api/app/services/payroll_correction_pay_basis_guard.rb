# frozen_string_literal: true

# Manual correction references retain source inputs, but do not replay a full
# historical calculator context. Current setup must not reinterpret those inputs.
class PayrollCorrectionPayBasisGuard
  MESSAGE = "The employee's pay basis differs from this correction's retained source payroll. Review the linked original payroll and pay setup before recalculating; current salary or fee pay cannot reinterpret retained correction earnings."

  def self.validate!(item)
    return true unless item.timekeeping_source == "correction_reference"

    source = item.financial_correction_origin_item || item.correction_for_payroll_item
    period = item.pay_period.source_pay_period || item.pay_period.corrects_pay_period
    # Simulation references without a declared source remain a separate path.
    return true unless source || period
    source ||= period.payroll_items.find_by(employee_id: item.employee_id, company_id: item.company_id)
    unless source && source.company_id == item.company_id && source.employee_id == item.employee_id &&
      (!period || period.company_id == item.company_id)
      raise ArgumentError, "This correction's original employee payroll is unavailable. Review its linked source payroll before recalculating."
    end

    basis = source.employment_type
    current = Employee.where(id: item.employee_id, company_id: item.company_id)
      .pick(:employment_type, :contractor_pay_type, :salary_type, :pay_frequency)
    raise ArgumentError, MESSAGE unless current && basis == item.employment_type && basis == current.first
    context = source.calculation_context_snapshot.to_h.fetch("employee", {}).to_h
    if context["employment_type"].present? && context["employment_type"] != basis
      raise ArgumentError, MESSAGE
    end
    subtype = basis == "contractor" ? "contractor_pay_type" : (basis == "salary" ? "salary_type" : nil)
    allowed = basis == "contractor" ? %w[hourly flat_fee] : %w[annual per_period variable]
    if subtype && !context[subtype].in?(allowed)
      raise ArgumentError, "This correction's original #{basis} pay basis is missing or unverified. Review retained original payroll evidence and pay setup with payroll support before recalculating; current setup cannot establish the original pay basis."
    end
    current_subtype = basis == "contractor" ? current[1] : current[2]
    if subtype && context[subtype].present? && context[subtype] != current_subtype
      raise ArgumentError, MESSAGE
    end
    validate_w2_frequency!(source, context, current[3]) if basis.in?(%w[hourly salary])
    true
  end

  def self.validate_w2_frequency!(source, context, current_frequency)
    timekeeping = source.timekeeping_context_snapshot.to_h
    tax = source.tax_rule_snapshot.to_h
    frequencies = [ context["pay_frequency"] ]
    if timekeeping["pay_basis"] == source.employment_type &&
      (source.hourly? || timekeeping["salary_type"] == context["salary_type"])
      frequencies << timekeeping["pay_frequency"]
    end
    frequencies << tax["pay_frequency"] if tax["engine"] == "legacy_tax_table"
    frequencies = frequencies.compact_blank.uniq
    # A company schedule cannot establish the original employee frequency:
    # employee overrides are supported, and schedule records are mutable.
    unless frequencies.one? && frequencies.first.in?(CompanyPaySchedule::FREQUENCIES)
      raise ArgumentError, "This correction's original #{source.employment_type} pay frequency is missing, unverified or inconsistent. Review retained original payroll evidence and pay setup before recalculating; today's employee or company frequency cannot establish it."
    end
    unless frequencies.first == current_frequency
      raise ArgumentError, "The employee's pay frequency differs from this correction's retained original #{source.employment_type} frequency. Review the linked original payroll and pay setup before recalculating; changing frequency changes withholding and can change period salary."
    end
  end
end
