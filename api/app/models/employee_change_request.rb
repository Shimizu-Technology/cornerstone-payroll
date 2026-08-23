# frozen_string_literal: true

class EmployeeChangeRequest < ApplicationRecord
  IDENTIFIER_KEYS = %i[ssn ssn_encrypted contractor_ein].freeze
  PERMITTED_EMPLOYEE_UPDATE_KEYS = %i[
    first_name
    middle_name
    last_name
    email
    ssn_encrypted
    date_of_birth
    hire_date
    termination_date
    department_id
    employment_type
    salary_type
    pay_rate
    pay_frequency
    filing_status
    allowances
    additional_withholding
    w4_dependent_credit
    w4_step2_multiple_jobs
    w4_step4a_other_income
    w4_step4b_deductions
    w4_form_version
    w4_effective_on
    retirement_rate
    roth_retirement_rate
    employer_retirement_match_rate
    employer_roth_match_rate
    business_name
    contractor_ein
    contractor_type
    contractor_pay_type
    w9_on_file
    address_line1
    address_line2
    city
    state
    zip
    phone
    default_custom_earnings
    default_payroll_adjustments
    status
    portal_pending_approval
  ].freeze

  encrypts :sensitive_payload_encrypted

  belongs_to :company
  belongs_to :employee
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  enum :status, { pending: 0, approved: 1, rejected: 2 }

  validates :proposed_changes, presence: true
  validates :requested_by, presence: true, on: :create
  validates :request_kind, inclusion: { in: %w[create update] }

  scope :recent_first, -> { order(created_at: :desc) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }

  def sensitive_payload
    return {} if sensitive_payload_encrypted.blank?

    JSON.parse(sensitive_payload_encrypted).deep_symbolize_keys
  rescue JSON::ParserError
    errors.add(:sensitive_payload_encrypted, "is invalid")
    raise ActiveRecord::RecordInvalid, self
  end

  def sensitive_payload=(payload)
    self.sensitive_payload_encrypted = payload.present? ? JSON.generate(payload) : nil
  end

  def apply!(actor:, review_notes: nil)
    ActiveRecord::Base.transaction do
      lock!
      ensure_pending!
      employee.lock!
      verify_original_values!
      apply_proposed_changes!
      update!(
        status: :approved,
        reviewed_by: actor,
        review_notes: review_notes,
        reviewed_at: Time.current
      )
    end
  end

  def reject!(actor:, review_notes:)
    with_lock do
      ensure_pending!
      update!(
        status: :rejected,
        reviewed_by: actor,
        review_notes: review_notes,
        reviewed_at: Time.current
      )
    end
  end

  private

  def ensure_pending!
    return if pending?

    errors.add(:status, "must be pending before review actions can be applied")
    raise ActiveRecord::RecordInvalid, self
  end

  def apply_proposed_changes!
    attrs = effective_proposed_changes
    wage_rates = attrs.delete(:wage_rates)
    validate_supported_change_keys!(attrs.keys)
    safe_attrs = attrs.slice(*PERMITTED_EMPLOYEE_UPDATE_KEYS)
    validate_department_scope!(safe_attrs)

    employee.update!(safe_attrs) if safe_attrs.present?
    return unless wage_rates.present?

    EmployeeWageRateSyncService.new(employee: employee, wage_rates: wage_rates).sync!
  end

  def effective_proposed_changes
    visible = normalize_proposed_changes(proposed_changes.deep_symbolize_keys)
    protected_values = normalize_proposed_changes(sensitive_payload.fetch(:proposed, {}))
    validate_protected_identifiers!(visible, protected_values)
    visible.except(*IDENTIFIER_KEYS).merge(protected_values)
  end

  def effective_original_values
    visible = normalize_proposed_changes(original_values.deep_symbolize_keys)
    protected_values = normalize_proposed_changes(sensitive_payload.fetch(:original, {}))
    visible.except(*IDENTIFIER_KEYS).merge(protected_values)
  end

  def normalize_proposed_changes(attrs)
    return attrs unless attrs[:ssn].present?

    attrs.except(:ssn).merge(ssn_encrypted: attrs[:ssn])
  end

  def validate_protected_identifiers!(visible, protected_values)
    missing = visible.keys.intersection(IDENTIFIER_KEYS) - protected_values.keys
    return if missing.empty?

    errors.add(
      :proposed_changes,
      "contains an identifier that must be resubmitted securely: #{missing.join(', ')}"
    )
    raise ActiveRecord::RecordInvalid, self
  end

  def verify_original_values!
    expected_values = effective_original_values.slice(*effective_proposed_changes.keys)
    conflicts = expected_values.each_with_object([]) do |(key, expected), fields|
      actual = current_value_for(key)
      fields << key unless comparable_value(key, actual) == comparable_value(key, expected)
    end
    return if conflicts.empty?

    errors.add(:base, "Employee data changed after this request was submitted: #{conflicts.join(', ')}")
    raise ActiveRecord::RecordInvalid, self
  end

  def current_value_for(key)
    return current_wage_rates_payload if key.to_sym == :wage_rates

    employee.public_send(key)
  end

  def current_wage_rates_payload
    employee.active_wage_rates.map do |rate|
      {
        id: rate.id,
        label: rate.label,
        rate: rate.rate.to_f,
        is_primary: rate.is_primary,
        active: rate.active
      }
    end
  end

  def comparable_value(key, value)
    return value.to_s.gsub(/\D/, "").presence if IDENTIFIER_KEYS.include?(key.to_sym)

    case value
    when BigDecimal, Numeric
      BigDecimal(value.to_s).to_s("F")
    when Date, Time, DateTime
      value.iso8601
    when Hash
      value.stringify_keys.sort.to_h.transform_values { |nested| comparable_value(:nested, nested) }
    when Array
      value.map { |nested| comparable_value(:nested, nested) }
    else
      value
    end
  end

  def validate_supported_change_keys!(keys)
    unsupported_keys = keys.map(&:to_sym) - PERMITTED_EMPLOYEE_UPDATE_KEYS - [ :wage_rates ]
    return if unsupported_keys.empty?

    errors.add(:proposed_changes, "contains unsupported fields: #{unsupported_keys.join(', ')}")
    raise ActiveRecord::RecordInvalid, self
  end

  def validate_department_scope!(attrs)
    return unless attrs.key?(:department_id)
    return if attrs[:department_id].blank?
    return if Department.exists?(id: attrs[:department_id], company_id: employee.company_id)

    errors.add(:proposed_changes, "contains a department outside the employee company")
    raise ActiveRecord::RecordInvalid, self
  end
end
