# frozen_string_literal: true

class ClientEmployeeUpdateService
  class PendingAddressRequest < StandardError
    attr_reader :request_id

    def initialize(request_id)
      @request_id = request_id
      super("An address request is already being reviewed for this employee.")
    end
  end

  WAGE_RATES_KEY = :wage_rates
  DIRECT_FIELDS = %i[
    first_name
    middle_name
    name_suffix
    last_name
    job_title
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
    default_custom_earnings
    default_payroll_adjustments
    wage_rates
  ].freeze
  LEGACY_RETIREMENT_FIELDS = %i[
    retirement_rate roth_retirement_rate employer_retirement_match_rate employer_roth_match_rate
  ].freeze
  PROTECTED_IDENTIFIER_FIELDS = %i[ssn_encrypted contractor_ein].freeze
  PAYMENT_METHOD_FIELD = :payment_delivery_method
  CLIENT_MANAGED_CREATE_FIELDS = (DIRECT_FIELDS + APPROVAL_FIELDS + [ PAYMENT_METHOD_FIELD ] - [ WAGE_RATES_KEY, :w4_election_received ]).freeze
  IDENTITY_TAX_FIELDS = %i[ssn_encrypted first_name middle_name last_name name_suffix date_of_birth hire_date].freeze
  TAX_FILING_IMPACT_FIELDS = %i[ssn_encrypted first_name middle_name last_name name_suffix].freeze
  CONTRACTOR_TAX_FIELDS = %i[business_name contractor_ein contractor_type w9_on_file].freeze
  COMPENSATION_VERIFICATION_FIELDS = %i[
    pay_rate employment_type salary_type pay_frequency contractor_pay_type
    wage_rates default_custom_earnings default_payroll_adjustments
  ].freeze
  W4_VERIFICATION_FIELDS = (EmployeeW4Election::PROFILE_ATTRIBUTES + [ :w4_election_received ]).freeze
  PROFILE_CHANGE_FIELDS = %i[job_title department_id email phone address_line1 address_line2 city state zip].freeze

  Result = Struct.new(
    :employee,
    :change_request,
    :applied_direct_fields,
    :approval_fields,
    :changed_fields,
    :before_values,
    :after_values,
    :contact_warnings,
    :same_person_email_confirmed,
    :confirmed_login_user_id,
    :readiness,
    :verification_items,
    :warnings,
    :client_managed,
    keyword_init: true
  )

  def initialize(employee:, attrs:, requested_by:, company:, confirm_same_person_email: false, row_revision: nil, baseline_values: nil,
                 email_locked: false)
    @employee = employee
    @email_locked = email_locked
    raw_attrs = attrs.deep_symbolize_keys
    @confirm_same_person_email = ActiveModel::Type::Boolean.new.cast(
      confirm_same_person_email || raw_attrs.delete(:confirm_same_person_email)
    ) == true
    @row_revision = row_revision.presence || raw_attrs.delete(:row_revision).presence || raw_attrs.delete(:contact_revision).presence
    @baseline_values = baseline_values.presence || raw_attrs.delete(:baseline_values)
    @compensation_effective_on = raw_attrs.delete(:compensation_effective_on).presence || raw_attrs.delete(:effective_on).presence
    @attrs = without_inapplicable_contractor_fields(normalize_attrs(raw_attrs))
    guard_legacy_recurring_components!
    @requested_by = requested_by
    @company = company
  end

  def guard_legacy_recurring_components!
    options = {}
    options[:payroll_adjustments] = @attrs[:default_payroll_adjustments] if @attrs.key?(:default_payroll_adjustments)
    options[:custom_earnings] = @attrs[:default_custom_earnings] if @attrs.key?(:default_custom_earnings)
    LegacyRecurringComponentGuard.validate!(employee: @employee, **options)
  end
  private :guard_legacy_recurring_components!

  def create!
    direct_attrs = attrs.slice(*DIRECT_FIELDS)
    approval_attrs = attrs.slice(*APPROVAL_FIELDS)
    candidate = nil
    change_request = nil
    contact_result = nil
    client_managed_result = nil

    ActiveRecord::Base.transaction do
      company.lock!
      ClientOperatingProfiles::LifecycleModeActivationService.ensure_attempted!(company)
      if client_managed_employee_lifecycle?
        client_managed_result = create_client_managed_in_lock!
        next
      end

      candidate = build_validated_candidate!(direct_attrs.merge(approval_attrs), creation: true)
      contact = apply_contact_changes!(direct_attrs, target: candidate, creation: true)
      contact_result = contact.validation

      create_attrs = direct_attrs.merge(
        company: company,
        pay_rate: 0,
        status: "inactive",
        portal_pending_approval: true,
        initial_compensation_source: "client_portal",
        initial_compensation_actor: requested_by
      )
      create_attrs[:contact_source] = contact.contact_source if contact.contact_source
      @employee = Employee.new(create_attrs)
      employee.intake_exception = candidate.intake_exception
      validate_department_scope!(direct_attrs)
      employee.save!
      EmployeeContactValidator.record_same_person_confirmation_audit!(
        employee: employee,
        result: contact_result,
        actor: requested_by,
        company: company
      )
      EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: requested_by)

      approval_attrs = approval_attrs.merge(status: "active", portal_pending_approval: false)
      change_request = create_change_request!(
        approval_attrs: approval_attrs,
        original_values: original_values_for(approval_attrs.keys),
        direct_changes: serialized_values_for(direct_attrs.keys),
        request_kind: "create"
      )
    end

    return client_managed_result if client_managed_result

    direct_fields = direct_attrs.keys
    approval_fields = approval_attrs.keys
    Result.new(
      employee: employee.reload,
      change_request: change_request,
      applied_direct_fields: direct_fields,
      approval_fields: approval_fields,
      changed_fields: direct_fields + approval_fields,
      before_values: {},
      after_values: serialized_values_for(direct_fields).merge(display_values_for(approval_attrs)),
      contact_warnings: contact_result&.warnings || [],
      same_person_email_confirmed: contact_result&.same_person_confirmed? || false,
      confirmed_login_user_id: contact_result&.same_person_confirmed? ? contact_result.matched_login_user&.id : nil,
      client_managed: false
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
    contact_result = nil
    client_managed_result = nil

    ActiveRecord::Base.transaction do
      company.lock!
      ClientOperatingProfiles::LifecycleModeActivationService.ensure_attempted!(company)
      if client_managed_employee_lifecycle?
        client_managed_result = update_client_managed_in_lock!
        next
      end

      employee.lock!
      EmployeeContactRevisionGuard.check!(
        employee: employee,
        row_revision: row_revision,
        submitted_attrs: attrs.slice(*DIRECT_FIELDS),
        baseline_values: baseline_values
      )
      direct_attrs = changed_attributes_subset(attrs.slice(*DIRECT_FIELDS))
      approval_attrs = changed_attributes_subset(attrs.slice(*APPROVAL_FIELDS).except(WAGE_RATES_KEY))
      if ActiveModel::Type::Boolean.new.cast(attrs[:w4_election_received])
        approval_attrs.merge!(attrs.slice(*EmployeeW4Election::PROFILE_ATTRIBUTES))
      end
      prevent_legacy_retirement_change!(approval_attrs)
      if attrs.key?(WAGE_RATES_KEY)
        normalized_wage_rates = normalized_wage_rates_payload(attrs[WAGE_RATES_KEY])
        approval_attrs[WAGE_RATES_KEY] = normalized_wage_rates if wage_rates_changed?(normalized_wage_rates)
      end

      request_kind = employee.portal_pending_approval? ? "create" : "update"
      if request_kind == "create" && approval_attrs.present?
        approval_attrs = approval_attrs.merge(status: "active", portal_pending_approval: false)
      end

      contact = apply_contact_changes!(direct_attrs, target: employee, creation: false)
      contact_result = contact.validation
      track_profile_changes = profile_requests_enabled?
      own_address = track_profile_changes ? extract_own_address!(direct_attrs, approval_attrs, contact_result) : {}

      validate_candidate!(direct_attrs.merge(approval_attrs, own_address)) if direct_attrs.present? || approval_attrs.present? || own_address.present?
      employee.require_ssn_confirmation = false
      employee.ssn_confirmation = nil
      direct_before = original_values_for(direct_attrs.keys)
      approval_attrs = own_address if own_address.present?
      approval_before = original_values_for(approval_attrs.keys)
      ensure_no_pending_request!(address_request: own_address.present?) if approval_attrs.present?
      if direct_attrs.present?
        update_attrs = direct_attrs.dup
        update_attrs[:contact_source] = contact.contact_source if contact.contact_source
        employee.update!(update_attrs)
        EmployeeContactValidator.record_same_person_confirmation_audit!(
          employee: employee,
          result: contact_result,
          actor: requested_by,
          company: company
        )
        record_contact_changes!(direct_before, direct_attrs.keys) if track_profile_changes
        EmployeeChangeRequest.supersede_pending_address!(employee: employee, actor: requested_by, changed_fields: direct_attrs.keys)
      end
      change_request = create_change_request!(
        approval_attrs: approval_attrs,
        original_values: approval_before,
        direct_changes: serialized_values_for(direct_attrs.keys),
        request_kind: own_address.present? ? "update" : request_kind,
        own_record: own_address.present?
      ) if approval_attrs.present?
    end

    return client_managed_result if client_managed_result

    direct_fields = direct_attrs.keys
    approval_fields = approval_attrs.keys
    Result.new(
      employee: employee.reload,
      change_request: change_request,
      applied_direct_fields: direct_fields,
      approval_fields: approval_fields,
      changed_fields: direct_fields + approval_fields,
      before_values: serialize_payload(direct_before).merge(display_values_for(approval_before)),
      after_values: serialized_values_for(direct_fields).merge(display_values_for(approval_attrs)),
      contact_warnings: contact_result&.warnings || [],
      same_person_email_confirmed: contact_result&.same_person_confirmed? || false,
      confirmed_login_user_id: contact_result&.same_person_confirmed? ? contact_result.matched_login_user&.id : nil,
      client_managed: false
    )
  end

  private

  attr_reader :employee, :attrs, :requested_by, :company, :confirm_same_person_email, :row_revision, :baseline_values

  def apply_contact_changes!(direct_attrs, target:, creation:)
    EmployeeContactChanges.new(
      employee: target, attributes: direct_attrs, company: company, actor: requested_by, source: "client",
      confirm_same_person_email: confirm_same_person_email, creation: creation, error_record: employee,
      email_locked: @email_locked
    ).apply!
  end

  def prevent_legacy_retirement_change!(approval_attrs)
    return if (approval_attrs.keys & LEGACY_RETIREMENT_FIELDS).empty?
    return unless employee.employee_retirement_elections.exists?

    employee.errors.add(:retirement_rate, "is managed in the dated retirement election; ask payroll staff to record the signed change")
    raise ActiveRecord::RecordInvalid, employee
  end

  def changed_attributes_subset(subset)
    subset.each_with_object({}) do |(key, value), changed|
      changed[key] = value if attribute_changed?(key, value)
    end
  end

  def attribute_changed?(key, value)
    current = key.to_sym == :w4_election_received ? false : current_employee_value(key)
    return EmployeeContactChanges.email_changed?(employee, value) if key.to_sym == :email
    return EmployeeContactChanges.phone_changed?(employee, value) if key.to_sym == :phone
    type = employee.class.attribute_types[key.to_s]
    if type&.type == :date && value.present?
      cast_date = type.cast(value)
      return true if cast_date.nil? # Keep malformed raw input for model validation.

      value = cast_date
    end
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

  def current_employee_value(key)
    if EmployeeCompensationChangeService::COMPENSATION_ATTRIBUTES.include?(key.to_s)
      EmployeeCompensationChangeService.snapshot(employee, PayrollBusinessClock.today).fetch(key.to_s)
    else
      employee.public_send(key)
    end
  end

  def original_values_for(keys)
    keys.each_with_object({}) do |key, values|
      values[key] = if key == WAGE_RATES_KEY
        current_wage_rates_payload
      elsif key.to_sym == :w4_election_received
        false
      else
        current_employee_value(key)
      end
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

  def wage_rates_changed?(normalized_wage_rates)
    normalize_compare_value(current_wage_rates_payload) != normalize_compare_value(normalized_wage_rates)
  end

  def build_validated_candidate!(candidate_attrs, creation: false)
    candidate = creation ? Employee.new : employee.dup
    candidate.intake_original_employee = employee unless creation
    candidate.assign_attributes(candidate_attrs.except(WAGE_RATES_KEY, :w4_election_received))
    candidate.company = company
    candidate.status = "active" if creation || employee.portal_pending_approval?
    candidate.portal_pending_approval = false
    candidate.require_ssn_confirmation = employee.require_ssn_confirmation
    candidate.ssn_confirmation = employee.ssn_confirmation
    EmployeeIntakePolicy.prepare!(candidate, actor: requested_by) if creation
    validate_received_withholding!(candidate_attrs, candidate: candidate)
    validate_tax_classification_change!(candidate)
    validate_department_scope!(candidate_attrs)
    normalized_wage_rates_payload(candidate_attrs[WAGE_RATES_KEY]) if candidate_attrs.key?(WAGE_RATES_KEY)
    return candidate if candidate.valid?

    candidate.errors.each { |error| employee.errors.add(error.attribute, error.message) }
    raise ActiveRecord::RecordInvalid, employee
  end

  def validate_received_withholding!(candidate_attrs, candidate:, source: "client_approved")
    w4_attrs = candidate_attrs.slice(*EmployeeW4Election::PROFILE_ATTRIBUTES)
    EmployeeW4ElectionChangeService.new(employee: candidate, actor: requested_by, source: source,
      reason: "Client submitted withholding election", attributes: w4_attrs,
      election_received: candidate_attrs[:w4_election_received]).validate_received_election!
    return if w4_attrs.empty?

    change = EmployeeW4ElectionChangeService.new(employee: employee.new_record? ? candidate : employee,
      actor: requested_by, source: source,
      reason: "Client submitted withholding election", attributes: w4_attrs,
      election_received: candidate_attrs[:w4_election_received])
    change.validate_default_replacement!
    return if candidate.contractor? || !change.effective_before_signature?

    employee.errors.add(:w4_effective_on, EmployeeW4Election::EFFECTIVE_BEFORE_SIGNATURE_MESSAGE)
    raise ActiveRecord::RecordInvalid, employee
  rescue EmployeeW4ElectionChangeService::Error => e
    employee.errors.add(:w4_election_received, e.message)
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

  def client_managed_employee_lifecycle?
    CompanyFeatures.for(company).client_managed_employee_lifecycle?
  end

  def create_client_managed_in_lock!
    create_attrs = attrs.slice(*CLIENT_MANAGED_CREATE_FIELDS)
    wage_rates_raw = attrs[WAGE_RATES_KEY]
    w4_election_received = ActiveModel::Type::Boolean.new.cast(attrs[:w4_election_received])

    new_employee = Employee.new(
      create_attrs.merge(
        company: company,
        status: "active",
        portal_pending_approval: false,
        readiness_gate_enforced: true,
        document_readiness_required: false,
        pay_rate: create_attrs[:pay_rate].presence || 0,
        initial_compensation_source: "client_portal",
        initial_compensation_actor: requested_by
      )
    )
    new_employee.require_ssn_confirmation = employee.require_ssn_confirmation
    new_employee.ssn_confirmation = employee.ssn_confirmation

    validate_department_scope!(create_attrs)
    contact_attrs = create_attrs.slice(*DIRECT_FIELDS)
    contact = apply_contact_changes!(contact_attrs, target: new_employee, creation: true)
    contact_result = contact.validation
    new_employee.email = contact_attrs[:email] if contact_attrs.key?(:email)
    new_employee.phone = contact_attrs[:phone] if contact_attrs.key?(:phone)
    new_employee.contact_source = contact.contact_source if contact.contact_source

    validate_duplicate_ssn!(new_employee.ssn_digits, target: new_employee) if new_employee.ssn_digits.present?
    if w4_supplied_on_create?(attrs, new_employee)
      validate_received_withholding!(attrs, candidate: new_employee, source: "client_direct")
    end
    normalized_wage_rates = attrs.key?(WAGE_RATES_KEY) ? normalized_wage_rates_payload(wage_rates_raw) : nil

    unless new_employee.valid?
      new_employee.errors.each { |error| employee.errors.add(error.attribute, error.message) }
      raise ActiveRecord::RecordInvalid, employee
    end

    @employee = new_employee
    employee.save!

    if normalized_wage_rates.present?
      apply_client_managed_compensation!(
        pay_rate: EmployeeCompensationChangeService::UNCHANGED,
        basis: {},
        wage_rates: normalized_wage_rates,
        effective_on: EmployeeCompensationChangeService.initial_effective_on(employee),
        reason: "Initial client-portal pay setup"
      )
    end

    if w4_supplied_on_create?(attrs, employee)
      w4_attrs = attrs.slice(*EmployeeW4Election::PROFILE_ATTRIBUTES)
      apply_client_managed_w4!(w4_attrs: w4_attrs, election_received: w4_election_received, reason: "Initial client-portal W-4 election")
    end

    EmployeeContactValidator.record_same_person_confirmation_audit!(
      employee: employee,
      result: contact_result,
      actor: requested_by,
      company: company
    )
    EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: requested_by)

    reloaded = employee.reload
    readiness = EmployeeReadinessEvaluator.evaluate(reloaded)
    submitted_fields = attrs.keys.reject { |key| attrs[key].nil? && key != :w9_on_file }
    after_display = display_values_for(attrs.slice(*submitted_fields))

    metadata = {
      "readiness_status" => readiness.status,
      "missing_keys" => readiness.missing_keys
    }
    if EmployeeProfileIdentity.possible_self_created_hire?(reloaded, requested_by, same_person_confirmed: contact_result&.same_person_confirmed?)
      metadata["possible_self_created_hire"] = true
    end
    metadata["direct_deposit_missing_bank_details"] = true if readiness.direct_deposit_missing_bank_details?

    verification_item = EmployeeVerificationItems::Recorder.record!(
      employee: reloaded,
      actor: requested_by,
      event_kind: "new_hire",
      changed_fields: submitted_fields,
      before_values: {},
      after_values: after_display,
      effective_on: reloaded.hire_date || PayrollBusinessClock.today,
      metadata: metadata
    )

    Result.new(
      employee: reloaded,
      change_request: nil,
      applied_direct_fields: submitted_fields,
      approval_fields: [],
      changed_fields: submitted_fields,
      before_values: {},
      after_values: after_display,
      contact_warnings: contact_result&.warnings || [],
      same_person_email_confirmed: contact_result&.same_person_confirmed? || false,
      confirmed_login_user_id: contact_result&.same_person_confirmed? ? contact_result.matched_login_user&.id : nil,
      readiness: readiness,
      verification_items: [ verification_item ],
      warnings: [],
      client_managed: true
    )
  end

  def update_client_managed_in_lock!
    prelock_payment_method_periods! if attrs.key?(PAYMENT_METHOD_FIELD)
    employee.lock!
    EmployeeContactRevisionGuard.check!(
      employee: employee,
      row_revision: row_revision,
      submitted_attrs: attrs.slice(*DIRECT_FIELDS),
      baseline_values: baseline_values
    )

    direct_attrs = changed_attributes_subset(attrs.slice(*DIRECT_FIELDS))
    approval_attrs = changed_attributes_subset(attrs.slice(*APPROVAL_FIELDS).except(WAGE_RATES_KEY))
    if ActiveModel::Type::Boolean.new.cast(attrs[:w4_election_received])
      approval_attrs.merge!(attrs.slice(*EmployeeW4Election::PROFILE_ATTRIBUTES))
    end
    prevent_legacy_retirement_change!(approval_attrs)
    if attrs.key?(WAGE_RATES_KEY)
      normalized_wage_rates = normalized_wage_rates_payload(attrs[WAGE_RATES_KEY])
      approval_attrs[WAGE_RATES_KEY] = normalized_wage_rates if wage_rates_changed?(normalized_wage_rates)
    end
    payment_method_attrs = changed_attributes_subset(attrs.slice(PAYMENT_METHOD_FIELD))

    contact = apply_contact_changes!(direct_attrs, target: employee, creation: false)
    contact_result = contact.validation

    confirming_own_login = contact_result&.same_person_confirmed? && contact_result.matched_login_user&.id == requested_by.id
    own_record = confirming_own_login || EmployeeProfileIdentity.own_record_for_client_managed?(employee, requested_by)

    if own_record
      return update_client_managed_own_record!(
        direct_attrs: direct_attrs,
        approval_attrs: approval_attrs,
        payment_method_attrs: payment_method_attrs,
        contact: contact,
        contact_result: contact_result
      )
    end

    all_changed = direct_attrs.merge(approval_attrs, payment_method_attrs)
    if all_changed.empty?
      reloaded = employee.reload
      return Result.new(
        employee: reloaded,
        change_request: nil,
        applied_direct_fields: [],
        approval_fields: [],
        changed_fields: [],
        before_values: {},
        after_values: {},
        contact_warnings: contact_result&.warnings || [],
        same_person_email_confirmed: contact_result&.same_person_confirmed? || false,
        confirmed_login_user_id: contact_result&.same_person_confirmed? ? contact_result.matched_login_user&.id : nil,
        readiness: EmployeeReadinessEvaluator.evaluate(reloaded),
        verification_items: [],
        warnings: [],
        client_managed: true
      )
    end

    validate_client_managed_update_candidate!(all_changed)
    ensure_payment_method_change_safe! if payment_method_attrs.present?

    before_raw = original_values_for(all_changed.keys)
    before_display = display_values_for(before_raw)
    after_display = display_values_for(all_changed)
    warnings = []

    comp_keys = EmployeeCompensationChangeService::COMPENSATION_ATTRIBUTES.map(&:to_sym) + [ WAGE_RATES_KEY ]
    w4_keys = EmployeeW4Election::PROFILE_ATTRIBUTES + [ :w4_election_received ]
    comp_attrs = all_changed.slice(*comp_keys)
    w4_attrs = all_changed.slice(*w4_keys)
    direct_model_attrs = all_changed.except(*comp_keys, *w4_keys, PAYMENT_METHOD_FIELD)

    if direct_model_attrs.present?
      update_attrs = direct_model_attrs.dup
      update_attrs[:contact_source] = contact.contact_source if contact.contact_source
      unless direct_model_attrs.key?(:ssn_encrypted)
        employee.require_ssn_confirmation = false
        employee.ssn_confirmation = nil
      end
      employee.update!(update_attrs)
      EmployeeContactValidator.record_same_person_confirmation_audit!(
        employee: employee,
        result: contact_result,
        actor: requested_by,
        company: company
      )
      record_contact_changes!(before_raw.slice(*direct_attrs.keys), direct_attrs.keys) if profile_requests_enabled? && direct_attrs.present?
      EmployeeChangeRequest.supersede_pending_address!(employee: employee, actor: requested_by, changed_fields: direct_attrs.keys)
    end

    if payment_method_attrs.present?
      EmployeePaymentDefaultService.new(
        employee: employee,
        method: payment_method_attrs[PAYMENT_METHOD_FIELD],
        actor: requested_by
      ).call
    end

    comp_result = nil
    if comp_attrs.present?
      requested_pay_rate = comp_attrs.key?(:pay_rate) ? comp_attrs[:pay_rate] : EmployeeCompensationChangeService::UNCHANGED
      basis = comp_attrs.slice(*EmployeeCompensationChangeService::BASIS_ATTRIBUTES.map(&:to_sym))
      comp_result = apply_client_managed_compensation!(
        pay_rate: requested_pay_rate,
        basis: basis,
        wage_rates: comp_attrs[WAGE_RATES_KEY],
        effective_on: @compensation_effective_on,
        reason: "Client portal compensation update"
      )
      warnings.concat(Array(comp_result&.warnings))
    end

    w4_election = nil
    if w4_attrs.present? && !employee.contractor?
      w4_election_received = ActiveModel::Type::Boolean.new.cast(w4_attrs[:w4_election_received])
      w4_profile = w4_attrs.slice(*EmployeeW4Election::PROFILE_ATTRIBUTES)
      w4_profile[:w4_effective_on] = next_unapproved_pay_date if w4_profile[:w4_effective_on].blank?
      w4_election = apply_client_managed_w4!(
        w4_attrs: w4_profile,
        election_received: w4_election_received,
        reason: "Client portal W-4 update"
      )
    end

    reloaded = employee.reload
    readiness = EmployeeReadinessEvaluator.evaluate(reloaded)
    verification_items, impact_warnings = record_client_managed_update_verifications!(
      reloaded: reloaded,
      all_changed: all_changed,
      before_display: before_display,
      after_display: after_display,
      readiness: readiness,
      comp_result: comp_result,
      w4_election: w4_election
    )
    warnings.concat(impact_warnings)

    Result.new(
      employee: reloaded,
      change_request: nil,
      applied_direct_fields: all_changed.keys,
      approval_fields: [],
      changed_fields: all_changed.keys,
      before_values: before_display,
      after_values: after_display,
      contact_warnings: contact_result&.warnings || [],
      same_person_email_confirmed: contact_result&.same_person_confirmed? || false,
      confirmed_login_user_id: contact_result&.same_person_confirmed? ? contact_result.matched_login_user&.id : nil,
      readiness: readiness,
      verification_items: verification_items,
      warnings: warnings.uniq,
      client_managed: true
    )
  end

  def update_client_managed_own_record!(direct_attrs:, approval_attrs:, payment_method_attrs:, contact:, contact_result:)
    address_keys = EmployeeChangeRequest::ADDRESS_FIELDS.map(&:to_sym)
    own_address_attrs = direct_attrs.extract!(*address_keys)
    non_address_restricted = approval_attrs.merge(payment_method_attrs)
    restricted_attrs = non_address_restricted.merge(own_address_attrs)
    is_address_only = restricted_attrs.present? && non_address_restricted.empty?

    combined = direct_attrs.merge(restricted_attrs)
    if combined.present?
      validate_client_managed_update_candidate!(combined)
    end

    employee.require_ssn_confirmation = false
    employee.ssn_confirmation = nil

    direct_before = original_values_for(direct_attrs.keys)
    restricted_before = original_values_for(restricted_attrs.keys)

    ensure_no_pending_request!(address_request: is_address_only) if restricted_attrs.present?

    verification_items = []
    if direct_attrs.present?
      update_attrs = direct_attrs.dup
      update_attrs[:contact_source] = contact.contact_source if contact.contact_source
      employee.update!(update_attrs)
      EmployeeContactValidator.record_same_person_confirmation_audit!(
        employee: employee,
        result: contact_result,
        actor: requested_by,
        company: company
      )
      record_contact_changes!(direct_before, direct_attrs.keys) if profile_requests_enabled?
      verification_items << EmployeeVerificationItems::Recorder.record!(
        employee: employee,
        actor: requested_by,
        event_kind: "profile_change",
        changed_fields: direct_attrs.keys,
        before_values: display_values_for(direct_before),
        after_values: serialized_values_for(direct_attrs.keys),
        affects_pay: false
      )
    end

    change_request = if restricted_attrs.present?
      create_change_request!(
        approval_attrs: restricted_attrs,
        original_values: restricted_before,
        direct_changes: serialized_values_for(direct_attrs.keys),
        request_kind: "update",
        own_record: true
      )
    end

    reloaded = employee.reload
    Result.new(
      employee: reloaded,
      change_request: change_request,
      applied_direct_fields: direct_attrs.keys,
      approval_fields: restricted_attrs.keys,
      changed_fields: direct_attrs.keys + restricted_attrs.keys,
      before_values: serialize_payload(direct_before).merge(display_values_for(restricted_before)),
      after_values: serialized_values_for(direct_attrs.keys).merge(display_values_for(restricted_attrs)),
      contact_warnings: contact_result&.warnings || [],
      same_person_email_confirmed: contact_result&.same_person_confirmed? || false,
      confirmed_login_user_id: contact_result&.same_person_confirmed? ? contact_result.matched_login_user&.id : nil,
      readiness: EmployeeReadinessEvaluator.evaluate(reloaded),
      verification_items: verification_items,
      warnings: [],
      client_managed: true
    )
  end

  def prelock_payment_method_periods!
    period_ids = PayrollItem.where(company_id: company.id, employee_id: employee.id, payment_delivery_method: nil)
      .joins(:pay_period).where(pay_periods: { status: %w[draft calculated approved] })
      .distinct.pluck(:pay_period_id).sort
    PayPeriod.where(id: period_ids).order(:id).lock.load if period_ids.any?
  end

  def ensure_payment_method_change_safe!
    return unless employee.payroll_items.where(payment_delivery_method: nil)
      .joins(:pay_period).where(pay_periods: { status: "approved" }).exists?

    employee.errors.add(
      :payment_delivery_method,
      "This employee is on an approved pay run awaiting commit — wait until commit or ask Cornerstone to update it."
    )
    raise ActiveRecord::RecordInvalid, employee
  end

  def validate_client_managed_update_candidate!(candidate_attrs)
    candidate = employee.dup
    candidate.intake_original_employee = employee
    candidate.assign_attributes(candidate_attrs.except(WAGE_RATES_KEY, :w4_election_received))
    candidate.company = company
    if candidate_attrs.key?(:ssn_encrypted)
      candidate.require_ssn_confirmation = employee.require_ssn_confirmation
      candidate.ssn_confirmation = employee.ssn_confirmation
      if candidate.ssn_digits.present? && candidate.ssn_digits != employee.ssn_digits
        validate_duplicate_ssn!(candidate.ssn_digits, target: employee)
      end
    else
      candidate.require_ssn_confirmation = false
      candidate.ssn_confirmation = nil
    end

    validate_received_withholding!(candidate_attrs, candidate: candidate, source: "client_direct")
    validate_tax_classification_change!(candidate)
    validate_department_scope!(candidate_attrs)
    normalized_wage_rates_payload(candidate_attrs[WAGE_RATES_KEY]) if candidate_attrs.key?(WAGE_RATES_KEY)
    return candidate if candidate.valid?

    candidate.errors.each { |error| employee.errors.add(error.attribute, error.message) }
    raise ActiveRecord::RecordInvalid, employee
  end

  def validate_duplicate_ssn!(ssn_digits, target:)
    return if ssn_digits.blank?

    excluded_ids = [ employee.id, employee.previous_employee_id, employee.next_employee&.id ].compact
    scope = company.employees.where("employees.ssn_encrypted IS NOT NULL AND employees.ssn_encrypted <> ''")
    scope = scope.where.not(id: excluded_ids) if excluded_ids.any?

    duplicate_exists = scope.select(:id, :ssn_encrypted).any? { |other| other.ssn_digits == ssn_digits }
    return unless duplicate_exists

    target.errors.add(:ssn, "This Social Security Number is already assigned to another employee in this company.")
    employee.errors.add(:ssn, "This Social Security Number is already assigned to another employee in this company.") unless target.equal?(employee)
    raise ActiveRecord::RecordInvalid, employee
  end

  def w4_supplied_on_create?(submitted_attrs, target)
    return false if target.contractor?

    ActiveModel::Type::Boolean.new.cast(submitted_attrs[:w4_election_received]) ||
      submitted_attrs[:w4_effective_on].present? ||
      submitted_attrs[:w4_signed_on].present? ||
      submitted_attrs[:w4_source_reference].present?
  end

  def apply_client_managed_compensation!(pay_rate:, basis:, wage_rates:, effective_on:, reason:)
    EmployeeCompensationChangeService.new(
      employee: employee,
      actor: requested_by,
      source: "client_portal",
      reason: reason,
      effective_on: effective_on,
      pay_rate: pay_rate,
      basis: basis,
      wage_rates: wage_rates.presence
    ).call!
  rescue EmployeeCompensationChangeService::Error => error
    employee.errors.add(:base, error.message)
    raise ActiveRecord::RecordInvalid, employee
  end

  def apply_client_managed_w4!(w4_attrs:, election_received:, reason:)
    EmployeeW4ElectionChangeService.new(
      employee: employee,
      attributes: w4_attrs,
      actor: requested_by,
      source: "client_direct",
      reason: reason,
      election_received: election_received
    ).call!
  rescue EmployeeW4ElectionChangeService::Error => error
    employee.errors.add(:w4_effective_on, error.message)
    raise ActiveRecord::RecordInvalid, employee
  end

  def next_unapproved_pay_date
    period = PayPeriod.where(
      company_id: company.id,
      status: %w[draft calculated],
      cycle: "regular",
      run_purpose: "regular",
      correction_status: nil,
      test_workspace_role: nil,
      parallel_run: false
    ).order(pay_date: :asc, id: :asc).first

    period&.pay_date || PayrollBusinessClock.today
  end

  def record_client_managed_update_verifications!(reloaded:, all_changed:, before_display:, after_display:, readiness:, comp_result:, w4_election:)
    items = []
    warnings = []
    changed_keys = all_changed.keys

    groups = [
      [ "compensation_change", changed_keys & COMPENSATION_VERIFICATION_FIELDS, comp_result&.effective_on, comp_result&.compensation_change, {} ],
      [ "w4_change", changed_keys & W4_VERIFICATION_FIELDS, w4_election&.effective_on, w4_election, {} ],
      [ "payment_method_change", changed_keys & [ PAYMENT_METHOD_FIELD ], nil, nil,
        readiness.direct_deposit_missing_bank_details? ? { "direct_deposit_missing_bank_details" => true } : {} ],
      [ "identity_tax_change", changed_keys & IDENTITY_TAX_FIELDS, nil, nil, {} ],
      [ "contractor_tax_change", changed_keys & CONTRACTOR_TAX_FIELDS, nil, nil, {} ],
      [ "profile_change", changed_keys & PROFILE_CHANGE_FIELDS, nil, nil, {} ]
    ]

    groups.each do |event_kind, group_keys, effective_on, source_record, group_metadata|
      next if group_keys.empty?

      if event_kind == "identity_tax_change" && (group_keys & TAX_FILING_IMPACT_FIELDS).any?
        impact = EmployeeVerificationItems::Recorder.tax_filing_impact_for(reloaded)
        if impact.present?
          group_metadata = group_metadata.merge("tax_filing_impact" => impact)
          warnings << "SSN or legal name changed after committed payroll in #{impact['committed_tax_years'].join(', ')} — Cornerstone will review W-2c / Form 941-GU amendment impact."
        end
      end

      string_keys = group_keys.map(&:to_s)
      items << EmployeeVerificationItems::Recorder.record!(
        employee: reloaded,
        actor: requested_by,
        event_kind: event_kind,
        changed_fields: string_keys,
        before_values: before_display.stringify_keys.slice(*string_keys),
        after_values: after_display.stringify_keys.slice(*string_keys),
        effective_on: effective_on,
        source_record: source_record,
        metadata: group_metadata
      )
    end

    EmployeeVerificationItems::Recorder.requeue_returned_items!(
      employee: reloaded,
      actor: requested_by,
      touched_fields: changed_keys
    )

    [ items, warnings ]
  end

  def profile_requests_enabled?
    CompanyFeatures.for(company).employee_portal_feature?(:profile_requests)
  end

  def extract_own_address!(direct_attrs, approval_attrs, contact_result)
    fields = EmployeeChangeRequest::ADDRESS_FIELDS.map(&:to_sym)
    return {} if direct_attrs.slice(*fields).empty?

    confirming_own_login = contact_result&.same_person_confirmed? && contact_result.matched_login_user&.id == requested_by.id
    return {} unless confirming_own_login || EmployeeProfileIdentity.own_record?(employee, requested_by)

    if approval_attrs.present?
      ensure_no_pending_request!(address_request: true)
      employee.errors.add(:base, "Submit your address separately from payroll-sensitive changes. Only one request can be reviewed at a time.")
      raise ActiveRecord::RecordInvalid, employee
    end
    direct_attrs.extract!(*fields)
  end

  def record_contact_changes!(before_values, fields)
    EmployeeContactChangeToConfirm.record!(
      employee: employee, actor: requested_by, before_values: before_values, after_values: serialized_values_for(fields)
    )
  end

  def ensure_no_pending_request!(address_request: false, collision: false)
    pending = EmployeeChangeRequest.for_company(company.id).find_by(employee: employee, status: :pending)
    return unless pending || collision

    if pending&.profile_address? && (profile_requests_enabled? || pending.requested_by_id == requested_by.id)
      raise PendingAddressRequest, pending.id
    end

    message = if address_request || pending&.profile_address?
      "#{EmployeeChangeRequest::PENDING_PROFILE_REQUEST_MESSAGE} for this employee."
    else
      "A payroll-sensitive change request is already pending for this employee"
    end
    employee.errors.add(:base, message)
    raise ActiveRecord::RecordInvalid, employee
  end

  def create_change_request!(approval_attrs:, original_values:, direct_changes:, request_kind:, own_record: false)
    proposed_visible, proposed_protected = protect_identifiers(approval_attrs)
    original_visible, original_protected = protect_identifiers(original_values)
    is_profile_address = own_record && request_kind == "update" &&
      (approval_attrs.keys.map(&:to_s) - EmployeeChangeRequest::ADDRESS_FIELDS).empty? &&
      proposed_protected.empty?

    notes = if is_profile_address
      "Client submitted an address change for their own employee record."
    elsif own_record
      "Client submitted payroll or tax changes for their own employee record for Cornerstone review."
    elsif request_kind == "create"
      "Client submitted a new worker's payroll details for approval."
    else
      "Client submitted payroll-sensitive employee changes for approval."
    end

    change_request = EmployeeChangeRequest.transaction(requires_new: true) do
      EmployeeChangeRequest.create!(
        company: company,
        employee: employee,
        requested_by: requested_by,
        request_kind: request_kind,
        own_record: own_record,
        proposed_changes: serialize_payload(proposed_visible),
        original_values: serialize_payload(original_visible),
        direct_changes_applied: serialize_payload(direct_changes),
        sensitive_payload: is_profile_address ? nil : {
          proposed: serialize_payload(proposed_protected),
          original: serialize_payload(original_protected)
        },
        request_notes: notes
      )
    end
    PortalNotifications.employee_change_submitted!(change_request)
    change_request
  rescue ActiveRecord::RecordNotUnique => error
    raise unless error.cause&.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) == "idx_employee_change_requests_one_pending"

    ensure_no_pending_request!(address_request: is_profile_address, collision: true)
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

  # Contractor settings mean nothing for a W-2 worker. The form still carries
  # their defaults, which would otherwise become no-op approval changes that
  # get saved onto the employee when staff approve the request.
  def without_inapplicable_contractor_fields(raw_attrs)
    target_type = raw_attrs[:employment_type].presence || employee.employment_type
    return raw_attrs if target_type.to_s == "contractor"

    raw_attrs.except(*Employee::CONTRACTOR_ONLY_ATTRIBUTES)
  end

  def normalize_attrs(raw_attrs)
    raw_attrs.each_with_object({}) do |(key, value), normalized|
      normalized[key] = key == WAGE_RATES_KEY ? value : cast_attribute_value(key, value)
    end
  end

  def cast_attribute_value(key, value)
    type = employee.class.attribute_types[key.to_s]
    return value unless type
    return value if type.type == :date

    type.cast(value)
  end
end
