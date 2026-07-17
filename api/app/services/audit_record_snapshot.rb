# frozen_string_literal: true

class AuditRecordSnapshot
  SAFE_FIELDS = {
    "Employee" => %w[
      first_name middle_name last_name email hire_date termination_date department_id job_title
      employment_type salary_type pay_rate pay_frequency filing_status allowances additional_withholding
      retirement_rate roth_retirement_rate employer_retirement_match_rate employer_roth_match_rate
      business_name contractor_type contractor_pay_type w9_on_file address_line1 address_line2 city state zip phone status
    ],
    "PayPeriod" => %w[start_date end_date pay_date pay_frequency status approved_at committed_at],
    "Company" => %w[name legal_name email phone address_line1 address_line2 city state zip status]
  }.freeze
  SENSITIVE_PATTERNS = /(ssn|password|token|secret|cipher|routing|account_number|bank_account|date_of_birth)/i

  class << self
    def changes_for(record)
      return empty_result unless record.respond_to?(:saved_changes)

      safe_fields = SAFE_FIELDS.fetch(record.class.name, [])
      before_values = {}
      after_values = {}
      redacted_fields = []

      record.saved_changes.each do |field, values|
        if field.match?(SENSITIVE_PATTERNS)
          redacted_fields << display_field(field)
        elsif safe_fields.include?(field)
          before_values[field] = serializable(values.first)
          after_values[field] = serializable(values.last)
        end
      end

      {
        before_values: before_values,
        after_values: after_values,
        changed_fields: (before_values.keys | after_values.keys | redacted_fields).sort,
        redacted_fields: redacted_fields.sort
      }
    end

    def subject_name(record)
      return if record.blank?
      return record.display_name if record.respond_to?(:display_name) && record.display_name.present?
      return record.name if record.respond_to?(:name) && record.name.present?
      return record.email if record.respond_to?(:email) && record.email.present?
      if record.respond_to?(:start_date) && record.respond_to?(:end_date)
        return "#{record.start_date&.strftime('%b %-d, %Y')} – #{record.end_date&.strftime('%b %-d, %Y')}"
      end

      nil
    end

    private

    def empty_result
      { before_values: {}, after_values: {}, changed_fields: [], redacted_fields: [] }
    end

    def display_field(field)
      field.sub(/_encrypted\z/, "")
    end

    def serializable(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value
    end
  end
end
