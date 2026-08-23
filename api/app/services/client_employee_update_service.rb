# frozen_string_literal: true

class ClientEmployeeUpdateService
  WAGE_RATES_KEY = :wage_rates
  DIRECT_FIELDS = %i[
    first_name
    middle_name
    last_name
    email
    date_of_birth
    hire_date
    department_id
    address_line1
    address_line2
    city
    state
    zip
    phone
  ].freeze
  APPROVAL_FIELDS = %i[
    ssn_encrypted
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
    default_custom_earnings
    default_payroll_adjustments
    wage_rates
  ].freeze
  PROTECTED_IDENTIFIER_FIELDS = %i[ssn_encrypted contractor_ein].freeze

  Result = Struct.new(
    :employee,
    :change_request,
    :applied_direct_fields,
    :approval_fields,
    :changed_fields,
    :before_values,
    :after_values,
    keyword_init: true
  )

  def initialize(employee:, attrs:, requested_by:, company:)
    @employee = employee
    @attrs = normalize_attrs(attrs.deep_symbolize_keys)
    @requested_by = requested_by
    @company = company
  end

  def create!
    direct_attrs = attrs.slice(*DIRECT_FIELDS)
    approval_attrs = attrs.slice(*APPROVAL_FIELDS)
    candidate = build_validated_candidate!(direct_attrs.merge(approval_attrs), creation: true)
    change_request = nil

    ActiveRecord::Base.transaction do
      @employee = Employee.new(direct_attrs.merge(
        company: company,
        pay_rate: 0,
        status: "inactive",
        portal_pending_approval: true
      ))
      validate_department_scope!(direct_attrs)
      employee.save!

      approval_attrs = approval_attrs.merge(status: "active", portal_pending_approval: false)
      change_request = create_change_request!(
        approval_attrs: approval_attrs,
        original_values: original_values_for(approval_attrs.keys),
        direct_changes: serialized_values_for(direct_attrs.keys),
        request_kind: "create"
      )
    end

    direct_fields = direct_attrs.keys
    approval_fields = approval_attrs.keys
    Result.new(
      employee: employee.reload,
      change_request: change_request,
      applied_direct_fields: direct_fields,
      approval_fields: approval_fields,
      changed_fields: direct_fields + approval_fields,
      before_values: {},
      after_values: serialized_values_for(direct_fields).merge(display_values_for(approval_attrs))
    )
  ensure
    candidate&.clear_changes_information
  end

  def update!
    direct_attrs = {}
    approval_attrs = {}
    direct_before = {}
    approval_before = {}
    change_request = nil

    ActiveRecord::Base.transaction do
      employee.lock!
      direct_attrs = changed_attributes_subset(attrs.slice(*DIRECT_FIELDS))
      approval_attrs = changed_attributes_subset(attrs.slice(*APPROVAL_FIELDS).except(WAGE_RATES_KEY))
      if attrs.key?(WAGE_RATES_KEY)
        normalized_wage_rates = normalized_wage_rates_payload(attrs[WAGE_RATES_KEY])
        approval_attrs[WAGE_RATES_KEY] = normalized_wage_rates if wage_rates_changed?(normalized_wage_rates)
      end

      request_kind = employee.portal_pending_approval? ? "create" : "update"
      if request_kind == "create" && approval_attrs.present?
        approval_attrs = approval_attrs.merge(status: "active", portal_pending_approval: false)
      end

      validate_candidate!(direct_attrs.merge(approval_attrs)) if direct_attrs.present? || approval_attrs.present?
      employee.require_ssn_confirmation = false
      employee.ssn_confirmation = nil
      direct_before = original_values_for(direct_attrs.keys)
      approval_before = original_values_for(approval_attrs.keys)
      ensure_no_pending_request! if approval_attrs.present?
      employee.update!(direct_attrs) if direct_attrs.present?
      change_request = create_change_request!(
        approval_attrs: approval_attrs,
        original_values: approval_before,
        direct_changes: serialized_values_for(direct_attrs.keys),
        request_kind: request_kind
      ) if approval_attrs.present?
    end

    direct_fields = direct_attrs.keys
    approval_fields = approval_attrs.keys
    Result.new(
      employee: employee.reload,
      change_request: change_request,
      applied_direct_fields: direct_fields,
      approval_fields: approval_fields,
      changed_fields: direct_fields + approval_fields,
      before_values: serialize_payload(direct_before).merge(display_values_for(approval_before)),
      after_values: serialized_values_for(direct_fields).merge(display_values_for(approval_attrs))
    )
  end

  private

  attr_reader :employee, :attrs, :requested_by, :company

  def changed_attributes_subset(subset)
    subset.each_with_object({}) do |(key, value), changed|
      changed[key] = value if attribute_changed?(key, value)
    end
  end

  def attribute_changed?(key, value)
    current = employee.public_send(key)
    normalize_compare_value(current) != normalize_compare_value(value)
  end

  def normalize_compare_value(value)
    case value
    when BigDecimal
      value.to_f.round(4)
    when Numeric
      value.to_f.round(4)
    when TrueClass, FalseClass
      value
    when Date, Time, DateTime
      value.to_s
    when Hash
      value.stringify_keys.sort.to_h.transform_values { |nested| normalize_compare_value(nested) }
    when Array
      value.map { |nested| normalize_compare_value(nested) }
    else
      value.presence
    end
  end

  def original_values_for(keys)
    keys.each_with_object({}) do |key, values|
      values[key] = key == WAGE_RATES_KEY ? current_wage_rates_payload : employee.public_send(key)
    end
  end

  def normalized_wage_rates_payload(raw_rates)
    raw = Array(raw_rates)
    normalized = EmployeeWageRateSyncService.normalize_payload(raw_rates)
    labels = normalized.map { |rate| rate[:label].to_s.downcase }
    supplied_ids = normalized.filter_map { |rate| rate[:id] }
    owned_ids = employee.persisted? ? employee.employee_wage_rates.where(id: supplied_ids).pluck(:id) : []

    if normalized.length != raw.length || labels.uniq.length != labels.length || normalized.any? { |rate| rate[:rate].nil? || rate[:rate].negative? }
      employee.errors.add(:wage_rates, "must contain unique labels and non-negative rates")
      raise ActiveRecord::RecordInvalid, employee
    end
    if supplied_ids.sort != owned_ids.sort
      employee.errors.add(:wage_rates, "must reference rates belonging to this employee")
      raise ActiveRecord::RecordInvalid, employee
    end

    normalized
  rescue ArgumentError, FloatDomainError
    employee.errors.add(:wage_rates, "must contain valid numeric rates")
    raise ActiveRecord::RecordInvalid, employee
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

  def wage_rates_changed?(normalized_wage_rates)
    normalize_compare_value(current_wage_rates_payload) != normalize_compare_value(normalized_wage_rates)
  end

  def build_validated_candidate!(candidate_attrs, creation: false)
    candidate = creation ? Employee.new : employee.dup
    candidate.assign_attributes(candidate_attrs.except(WAGE_RATES_KEY))
    candidate.company = company
    candidate.status = "active" if creation || employee.portal_pending_approval?
    candidate.portal_pending_approval = false
    candidate.require_ssn_confirmation = employee.require_ssn_confirmation
    candidate.ssn_confirmation = employee.ssn_confirmation
    validate_tax_classification_change!(candidate)
    validate_department_scope!(candidate_attrs)
    normalized_wage_rates_payload(candidate_attrs[WAGE_RATES_KEY]) if candidate_attrs.key?(WAGE_RATES_KEY)
    return candidate if candidate.valid?

    candidate.errors.each { |error| employee.errors.add(error.attribute, error.message) }
    raise ActiveRecord::RecordInvalid, employee
  end

  def validate_candidate!(candidate_attrs)
    build_validated_candidate!(candidate_attrs)
  end

  def validate_tax_classification_change!(candidate)
    return if employee.new_record?
    return if (employee.employment_type == "contractor") == (candidate.employment_type == "contractor")

    employee.errors.add(:employment_type, "cannot change between W-2 and 1099 in place; create a new worker record")
    raise ActiveRecord::RecordInvalid, employee
  end

  def validate_department_scope!(attrs_to_apply)
    return unless attrs_to_apply.key?(:department_id)
    return if attrs_to_apply[:department_id].blank?
    return if Department.exists?(id: attrs_to_apply[:department_id], company_id: company.id)

    employee.errors.add(:department_id, "does not belong to this company")
    raise ActiveRecord::RecordInvalid, employee
  end

  def ensure_no_pending_request!
    return unless EmployeeChangeRequest.where(employee: employee, status: :pending).exists?

    employee.errors.add(:base, "A payroll-sensitive change request is already pending for this employee")
    raise ActiveRecord::RecordInvalid, employee
  end

  def create_change_request!(approval_attrs:, original_values:, direct_changes:, request_kind:)
    proposed_visible, proposed_protected = protect_identifiers(approval_attrs)
    original_visible, original_protected = protect_identifiers(original_values)

    EmployeeChangeRequest.create!(
      company: company,
      employee: employee,
      requested_by: requested_by,
      request_kind: request_kind,
      proposed_changes: serialize_payload(proposed_visible),
      original_values: serialize_payload(original_visible),
      direct_changes_applied: serialize_payload(direct_changes),
      sensitive_payload: {
        proposed: serialize_payload(proposed_protected),
        original: serialize_payload(original_protected)
      },
      request_notes: request_kind == "create" ?
        "Client submitted a new worker's payroll details for approval." :
        "Client submitted payroll-sensitive employee changes for approval."
    )
  rescue ActiveRecord::RecordNotUnique
    employee.errors.add(:base, "A payroll-sensitive change request is already pending for this employee")
    raise ActiveRecord::RecordInvalid, employee
  end

  def protect_identifiers(values)
    values.each_with_object([ {}, {} ]) do |(key, value), (visible, protected)|
      if PROTECTED_IDENTIFIER_FIELDS.include?(key.to_sym)
        visible[key] = masked_identifier(key, value)
        protected[key] = value
      else
        visible[key] = value
      end
    end
  end

  def masked_identifier(key, value)
    digits = value.to_s.gsub(/\D/, "")
    return nil if digits.blank?
    return "***-**-#{digits.last(4)}" if key.to_sym == :ssn_encrypted

    "Ending in #{digits.last(4)}"
  end

  def display_values_for(values)
    visible, = protect_identifiers(values)
    serialize_payload(visible)
  end

  def serialize_payload(value)
    case value
    when Hash
      value.transform_values { |nested| serialize_payload(nested) }
    when Array
      value.map { |nested| serialize_payload(nested) }
    when BigDecimal
      value.to_f
    when Date, Time, DateTime
      value.iso8601
    else
      value
    end
  end

  def serialized_values_for(keys)
    serialize_payload(original_values_for(keys))
  end

  def normalize_attrs(raw_attrs)
    raw_attrs.each_with_object({}) do |(key, value), normalized|
      normalized[key] = key == WAGE_RATES_KEY ? value : cast_attribute_value(key, value)
    end
  end

  def cast_attribute_value(key, value)
    type = employee.class.attribute_types[key.to_s]
    return value unless type

    type.cast(value)
  end
end
