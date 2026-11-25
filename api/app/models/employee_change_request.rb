# frozen_string_literal: true

class EmployeeChangeRequest < ApplicationRecord
  include PortalInboxUpdates
  PENDING_PROFILE_REQUEST_MESSAGE = "A change is already being reviewed"
  ADDRESS_FIELDS = %w[address_line1 address_line2 city state zip].freeze
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
    w4_signed_on
    w4_source_reference
    w4_effective_on
    w4_election_received
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
  belongs_to :requested_by_link, class_name: "EmployeeAccountLink", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  enum :status, { pending: 0, approved: 1, rejected: 2 }

  validates :proposed_changes, presence: true
  validates :requested_by, presence: true, on: :create
  validates :request_kind, inclusion: { in: %w[create update] }

  validate :validate_profile_address_origin, on: :create, if: :profile_address_origin?

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }

  scope :profile_addresses, -> {
    where("own_record OR requested_by_link_id IS NOT NULL").where(request_kind: "update", sensitive_payload_encrypted: nil)
      .where("jsonb_typeof(proposed_changes) = 'object' AND proposed_changes <> '{}'::jsonb")
      .where("proposed_changes - ARRAY[?]::text[] = '{}'::jsonb", ADDRESS_FIELDS)
      .where(%q{NOT jsonb_path_exists(proposed_changes, '$.* ? (@.type() != "string" && @.type() != "null")')})
  }

  def profile_address_origin?
    own_record? || requested_by_link_id.present?
  end

  def profile_address?
    profile_address_origin? && request_kind == "update" && sensitive_payload_encrypted_before_type_cast.nil? &&
      proposed_changes.is_a?(Hash) && proposed_changes.present? &&
      (proposed_changes.keys.map(&:to_s) - ADDRESS_FIELDS).empty? &&
      proposed_changes.values.all? { |value| value.nil? || value.is_a?(String) }
  end

  def same_person_reviewer?(actor)
    requested_by_id == actor.id || requested_by_link&.user_id == actor.id ||
      EmployeeProfileIdentity.own_record?(employee, actor)
  end

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

  def compensation_requested?
    (proposed_changes.keys.map(&:to_s) & (EmployeeCompensationChangeService::COMPENSATION_ATTRIBUTES + %w[wage_rates])).any?
  end

  def proposed_compensation_effective_on
    return unless compensation_requested?

    default = EmployeeCompensationChangeService.default_effective_on(employee)
    request_kind == "create" ? default : [ PayrollBusinessClock.today, default ].max
  end

  def apply!(actor:, review_notes: nil, effective_on: nil)
    ActiveRecord::Base.transaction do
      Company.lock.find(company_id)
      lock!
      ensure_pending!
      employee.lock!
      actor = authorized_review_actor!(actor)
      verify_original_values!
      if profile_address?
        apply_profile_address!(reviewer: actor)
      else
        apply_proposed_changes!(actor: actor, effective_on: effective_on.presence || proposed_compensation_effective_on)
      end
      if request_kind == "create"
        record_new_hire_contact_changes!(reviewer: actor)
        EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: actor)
      end
      update!(
        status: :approved,
        reviewed_by: actor,
        review_notes: review_notes,
        reviewed_at: Time.current
      )
      notify_decision!(actor)
    end
  end

  def reject!(actor:, review_notes:)
    self.class.transaction do
      Company.lock.find(company_id) if profile_address_origin?
      lock!
      ensure_pending!
      actor = authorized_review_actor!(actor)
      update!(
        status: :rejected,
        reviewed_by: actor,
        review_notes: review_notes,
        reviewed_at: Time.current
      )
      notify_decision!(actor)
    end
  end

  private

  def notify_decision!(actor)
    if requested_by_link_id.present?
      PortalNotifications.employee_address_decided!(self, actor: actor)
    else
      PortalNotifications.employee_change_decided!(self, actor: actor)
    end
  end

  def authorized_review_actor!(actor)
    actor = User.lock.find_by(id: actor&.id)
    company.company_assignments.where(user_id: actor&.id).lock.load
    if actor&.payroll_access_allowed? && actor.can_access_company?(company_id) &&
        (StaffRolePolicy.allowed?(actor, :manage_client_configuration, company: company) || client_address_reviewer?(actor))
      return actor unless profile_address_origin? && same_person_reviewer?(actor)

      errors.add(:base, "Someone else must review a change to your own record or a request you submitted")
    else
      errors.add(:base, "Client configuration access required")
    end
    raise ActiveRecord::RecordInvalid, self
  end

  def client_address_reviewer?(actor)
    actor.client? && actor.organization_id == company.organization_id && profile_address? &&
      CompanyFeatures.for(company).employee_portal_feature?(:profile_requests)
  end

  def validate_profile_address_origin
    unless profile_address? && original_values.is_a?(Hash) &&
        proposed_changes.keys.map(&:to_s).all? { |key| original_values.stringify_keys.key?(key) }
      errors.add(:proposed_changes, "must contain only address fields and their original values")
    end
    if requested_by_link_id.present?
      unless requested_by_link && requested_by_link.user_id == requested_by_id &&
          requested_by_link.employee_id == employee_id && requested_by_link.company_id == company_id
        errors.add(:requested_by_link, "must match the requester and employee")
      end
    elsif !requested_by&.client? || employee.company_id != company_id || !EmployeeProfileIdentity.own_record?(employee, requested_by)
      errors.add(:own_record, "must be the client requester’s employee record")
    end
  end

  def apply_profile_address!(reviewer:)
    before_values = employee.slice(*proposed_changes.keys)
    employee.update!(proposed_changes)
    EmployeeContactChangeToConfirm.record!(
      employee: employee, actor: requested_by, before_values: before_values,
      after_values: employee.slice(*proposed_changes.keys), reviewer: reviewer, notify_staff: requested_by_link_id.present?
    )
  end

  def record_new_hire_contact_changes!(reviewer:)
    return unless CompanyFeatures.for(company).employee_portal_feature?(:profile_requests)

    fields = direct_changes_applied.keys & EmployeeContactChangeToConfirm::FIELDS.values.flatten
    EmployeeContactChangeToConfirm.record!(
      employee: employee, actor: requested_by, before_values: {},
      after_values: employee.slice(*fields), reviewer: reviewer
    )
  end

  def ensure_pending!
    return if pending?

    errors.add(:status, "must be pending before review actions can be applied")
    raise ActiveRecord::RecordInvalid, self
  end

  def apply_proposed_changes!(actor:, effective_on:)
    attrs = effective_proposed_changes
    wage_rates = attrs.delete(:wage_rates)
    validate_supported_change_keys!(attrs.keys)
    safe_attrs = attrs.slice(*PERMITTED_EMPLOYEE_UPDATE_KEYS)
    # Requests submitted before the portal stopped sending contractor defaults
    # for W-2 workers may still carry them; never save them onto a W-2 worker.
    unless (safe_attrs[:employment_type].presence || employee.employment_type).to_s == "contractor"
      safe_attrs = safe_attrs.except(*Employee::CONTRACTOR_ONLY_ATTRIBUTES)
    end
    validate_department_scope!(safe_attrs)
    validate_and_normalize_contact_attrs!(safe_attrs, actor: actor)

    election_received = safe_attrs.delete(:w4_election_received)
    w4_attrs = safe_attrs.extract!(*EmployeeW4Election::PROFILE_ATTRIBUTES)

    requested_pay_rate = safe_attrs.key?(:pay_rate) ? safe_attrs.delete(:pay_rate) : EmployeeCompensationChangeService::UNCHANGED
    basis = safe_attrs.extract!(*EmployeeCompensationChangeService::BASIS_ATTRIBUTES.map(&:to_sym))
    employee.update!(safe_attrs) if safe_attrs.present?
    EmployeeW4ElectionChangeService.new(
      employee: employee,
      attributes: w4_attrs,
      actor: actor,
      source: "client_approved",
      reason: "Approved client employee change request ##{id}", election_received: election_received
    ).call! if w4_attrs.present?

    EmployeeCompensationChangeService.new(
      employee: employee,
      actor: actor,
      source: "client_approved",
      reason: "Approved client employee change request ##{id}",
      effective_on: effective_on,
      pay_rate: requested_pay_rate,
      basis: basis,
      reject_scheduled_conflict: true,
      wage_rates: wage_rates.presence
    ).call!
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
    return false if key.to_sym == :w4_election_received

    if EmployeeCompensationChangeService::COMPENSATION_ATTRIBUTES.include?(key.to_s)
      EmployeeCompensationChangeService.snapshot(employee, PayrollBusinessClock.today).fetch(key.to_s)
    else
      employee.public_send(key)
    end
  end

  def current_wage_rates_payload
    employee.wage_rates_on(PayrollBusinessClock.today).map do |rate|
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

  def validate_and_normalize_contact_attrs!(safe_attrs, actor:)
    return unless safe_attrs.key?(:email) || safe_attrs.key?(:phone)

    result = EmployeeContactValidator.call(
      employee: employee,
      company: company,
      email: safe_attrs.key?(:email) ? safe_attrs[:email] : :unchanged,
      phone: safe_attrs.key?(:phone) ? safe_attrs[:phone] : :unchanged,
      actor: actor,
      source: "client"
    )
    unless result.valid?
      result.errors.each do |field, messages|
        messages.each { |message| errors.add(field, message) }
      end
      raise ActiveRecord::RecordInvalid, self
    end

    safe_attrs[:email] = result.normalized_email if safe_attrs.key?(:email)
    safe_attrs[:phone] = result.normalized_phone if safe_attrs.key?(:phone)
    safe_attrs[:contact_source] = "client"
  end

  def validate_department_scope!(attrs)
    return unless attrs.key?(:department_id)
    return if attrs[:department_id].blank?
    return if Department.exists?(id: attrs[:department_id], company_id: employee.company_id)

    errors.add(:proposed_changes, "contains a department outside the employee company")
    raise ActiveRecord::RecordInvalid, self
  end
end
