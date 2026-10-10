# frozen_string_literal: true

# Correction drafts retain the earned rate snapshot while accepting new hours.
# An inactive profile rate is usable only when the immutable source used it.
class PayrollWageRateInput
  def self.normalize(payroll_item:, entries:)
    employee = payroll_item.employee
    source_item = if payroll_item.timekeeping_source == "correction_reference"
      payroll_item.pay_period.source_pay_period&.payroll_items&.find_by(employee_id: employee.id)
    end
    saved_entries = Array(source_item&.wage_rate_hours)
    Array(entries).map do |raw|
      data = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      raise ArgumentError, "Wage-rate hours must contain objects" unless data.is_a?(Hash)
      data = data.stringify_keys
      id = data["employee_wage_rate_id"]
      next data if id.blank? # Legacy named custom rate buckets have no profile ID.
      raise ArgumentError, "Wage-rate ID is invalid" unless id.to_s.match?(/\A[1-9]\d*\z/)
      rate = employee.employee_wage_rates.find_by(id: id)
      raise ArgumentError, "Wage rate does not belong to this employee" unless rate
      saved = saved_entries.find { |entry| entry["employee_wage_rate_id"].to_s == id.to_s }
      unless rate.active? || saved
        raise ArgumentError, "Inactive wage rate was not part of this payroll's original rate snapshot"
      end
      if saved && BigDecimal(data["rate"].to_s) != saved["rate"].to_d
        raise ArgumentError, "Retain this payroll's saved original wage rates; a rate change requires a reviewed wage-rate correction"
      end
      saved ? data.merge(saved.slice("rate", "label", "is_primary", "active")) : data
    end
  end
end
