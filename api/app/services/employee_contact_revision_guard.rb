# frozen_string_literal: true

# Guards row-level concurrent edits to employee contact/profile fields using the
# employee's updated_at revision token. When the row revision is stale:
# - If baseline_values are provided for every submitted field, only fields whose
#   current DB value diverged from the caller's baseline count as conflicts (so
#   non-overlapping edits by coworkers merge cleanly).
# - If baseline_values are omitted or incomplete, any stale revision conflicts.
class EmployeeContactRevisionGuard
  class ConflictError < StandardError
    attr_reader :employee, :conflicting_fields, :current_values

    def initialize(employee:, conflicting_fields:, current_values:)
      @employee = employee
      @conflicting_fields = conflicting_fields
      @current_values = current_values
      super("This employee's contact details were updated by someone else. Review the latest values and choose whether to keep or discard your changes.")
    end
  end

  def self.check!(employee:, row_revision:, submitted_attrs:, baseline_values: nil)
    return if row_revision.blank?

    current_revision = employee.contact_revision
    return if current_revision.present? && row_revision.to_s == current_revision

    submitted_keys = submitted_attrs.keys.map(&:to_sym)
    baseline = normalize_baseline(baseline_values)

    conflicting_fields = if baseline.present? && submitted_keys.any? && submitted_keys.all? { |key| baseline.key?(key) }
      submitted_keys.select do |key|
        field_diverged?(employee, key, baseline[key])
      end
    else
      submitted_keys.presence || [ :updated_at ]
    end

    return if conflicting_fields.empty?

    raise ConflictError.new(
      employee: employee,
      conflicting_fields: conflicting_fields.map(&:to_s),
      current_values: current_contact_values(employee)
    )
  end

  def self.current_contact_values(employee)
    EmployeeContactValidator::CONTACT_FIELDS.each_with_object({}) do |field, acc|
      acc[field.to_s] = employee.public_send(field)
    end
  end

  def self.normalize_baseline(raw)
    return {} unless raw.respond_to?(:to_h)

    raw.to_h.symbolize_keys
  end

  def self.field_diverged?(employee, key, expected_value)
    return true unless employee.respond_to?(key)

    current = employee.public_send(key)
    case key
    when :email
      EmployeeContactValidator.normalize_email(current) != EmployeeContactValidator.normalize_email(expected_value)
    when :phone
      norm_current, = EmployeeContactValidator.normalize_phone(current)
      norm_expected, expected_error = EmployeeContactValidator.normalize_phone(expected_value)
      comparable_expected = expected_error.present? ? expected_value.to_s.strip.presence : norm_expected
      (norm_current || current.to_s.strip.presence) != comparable_expected
    else
      current.to_s.strip.presence != expected_value.to_s.strip.presence
    end
  end
  private_class_method :normalize_baseline, :field_diverged?
end
