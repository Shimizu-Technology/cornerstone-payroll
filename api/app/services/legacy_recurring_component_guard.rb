# frozen_string_literal: true

# Legacy employee JSON defaults remain readable so historical clients continue
# to calculate, but new or edited recurring payroll behavior must use typed
# PayrollFieldDefinition and EmployeePayrollField records. Removing legacy rows
# is intentionally allowed so clients can migrate without a flag day.
class LegacyRecurringComponentGuard
  class Error < StandardError; end

  def self.validate!(employee:, payroll_adjustments: :not_supplied, custom_earnings: :not_supplied)
    if payroll_adjustments != :not_supplied
      validate_reduction!(
        current: Employee.normalize_payroll_adjustments(employee&.default_payroll_adjustments),
        proposed: Employee.normalize_payroll_adjustments(payroll_adjustments),
        label: "legacy recurring adjustments"
      )
    end
    if custom_earnings != :not_supplied
      validate_reduction!(
        current: normalize_custom_earnings(employee&.default_custom_earnings),
        proposed: normalize_custom_earnings(custom_earnings),
        label: "legacy recurring earnings"
      )
    end
  end

  def self.validate_reduction!(current:, proposed:, label:)
    current_counts = Array(current).map { |entry| canonical(entry) }.tally
    proposed_counts = Array(proposed).map { |entry| canonical(entry) }.tally
    added_or_changed = proposed_counts.any? { |signature, count| count > current_counts.fetch(signature, 0) }
    return unless added_or_changed

    raise Error, "New or changed #{label} must use Assigned Payroll Fields so type, effective dates, reporting, and payee behavior are explicit. Existing legacy rows may only be removed."
  end
  private_class_method :validate_reduction!

  def self.canonical(entry)
    entry.to_h.deep_stringify_keys.sort.to_h.to_json
  end
  private_class_method :canonical

  def self.normalize_custom_earnings(entries)
    normalized = Array(entries).map do |entry|
      data = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h
      data.deep_stringify_keys
    end
    PayrollItem.normalize_custom_earning_entries(normalized)
  end
  private_class_method :normalize_custom_earnings
end
