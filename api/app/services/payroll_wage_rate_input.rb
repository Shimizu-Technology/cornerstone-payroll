# frozen_string_literal: true

# Correction drafts retain the earned rate snapshot while accepting new hours.
# An inactive or deleted profile rate is usable only when the source used it.
class PayrollWageRateInput
  def self.normalize(payroll_item:, entries:)
    employee = payroll_item.employee
    correction_source = payroll_item.timekeeping_source == "correction_reference" &&
      (payroll_item.pay_period.source_pay_period_id.present? || payroll_item.pay_period.correction_run?)
    source_item = if payroll_item.timekeeping_source == "correction_reference"
      source = payroll_item.pay_period.source_pay_period
      if source&.company_id == payroll_item.company_id
        source.payroll_items.find_by(employee_id: employee.id, company_id: payroll_item.company_id)
      end
    end
    saved_entries = Array(source_item&.wage_rate_hours)
    Array(entries).map do |raw|
      data = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      raise ArgumentError, "Wage-rate hours must contain objects" unless data.is_a?(Hash)
      data = data.stringify_keys
      id = data["employee_wage_rate_id"]
      if id.blank?
        # Legacy buckets remain editable outside an explicitly sourced correction.
        next data unless correction_source
        matches = saved_entries.select { |entry| data["label"].present? && entry["label"] == data["label"] }
        unless matches.one? && matches.first["employee_wage_rate_id"].blank?
          raise ArgumentError, "Retain one identifiable original legacy wage-rate bucket; do not remove original wage-rate IDs"
        end
        saved = matches.first
        requested_rate = BigDecimal(data["rate"].to_s)
        original_rate = saved["rate"].to_d
        unless requested_rate.finite? && original_rate.finite? && original_rate.positive? && requested_rate == original_rate
          raise ArgumentError, "Retain this payroll's saved original wage rates; a rate change requires a reviewed wage-rate correction"
        end
        next data.merge(saved.slice("employee_wage_rate_id", "rate", "label", "is_primary", "active"))
      end
      raise ArgumentError, "Wage-rate ID is invalid" unless id.to_s.match?(/\A[1-9]\d*\z/)
      saved = saved_entries.find { |entry| entry["employee_wage_rate_id"].to_s == id.to_s }
      rate = employee.employee_wage_rates.find_by(id: id)
      raise ArgumentError, "Wage rate does not belong to this employee" unless saved || rate
      unless saved || rate.active?
        raise ArgumentError, "Inactive wage rate was not part of this payroll's original rate snapshot"
      end
      if saved && BigDecimal(data["rate"].to_s) != saved["rate"].to_d
        raise ArgumentError, "Retain this payroll's saved original wage rates; a rate change requires a reviewed wage-rate correction"
      end
      saved ? data.merge(saved.slice("rate", "label", "is_primary", "active")) : data
    end
  end
end
