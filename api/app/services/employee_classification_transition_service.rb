# frozen_string_literal: true

class EmployeeClassificationTransitionService
  class Error < StandardError; end

  Result = Struct.new(:previous_employee, :new_employee, :contact_notices, keyword_init: true)
  BLANKED_EMAIL_NOTICE = "The email on the old record wasn't copied, because it can't be used for this worker. " \
    "Enter the worker's own email on the new record."

  def initialize(employee:, attributes:, actor:)
    @employee = employee
    @attributes = attributes.to_h.deep_symbolize_keys
    @actor = actor
  end

  def call
    authorize!

    Employee.transaction do
      employee.company.lock!
      employee.lock!
      validate_transition!

      new_employee = Employee.new(new_employee_attributes.merge(initial_compensation_source: "classification_transition", initial_compensation_actor: actor))
      contact_result = validate_contact_details!(new_employee)
      apply_validated_contact_details!(new_employee, contact_result)
      EmployeeIntakePolicy.prepare!(new_employee, actor: actor)
      new_employee.save!
      create_w4_election!(new_employee)
      create_primary_wage_rate!(new_employee)
      EmployeeDocumentReadiness.seed_new_hire!(employee: new_employee, actor: actor)

      employee.update!(
        status: "terminated",
        termination_date: effective_date - 1.day
      )

      audit_metadata = {
        previous_employee_id: employee.id,
        new_employee_id: new_employee.id,
        from_tax_classification: employee.tax_classification,
        to_tax_classification: new_employee.tax_classification,
        from_employment_type: employee.employment_type,
        to_employment_type: new_employee.employment_type,
        effective_date: effective_date.iso8601,
        reason: reason,
        historical_payroll_preserved: true
      }
      if contact_result.same_person_confirmed?
        audit_metadata[:same_person_email_confirmed] = true
        audit_metadata[:confirmed_login_user_id] = contact_result.matched_login_user&.id
      end

      AuditLog.record!(
        user: actor,
        company_id: employee.company_id,
        action: "employees#transition_tax_classification",
        record_type: "employees",
        record_id: new_employee.id,
        subject_name: new_employee.display_name,
        metadata: audit_metadata
      )

      Result.new(previous_employee: employee.reload, new_employee: new_employee.reload, contact_notices: @contact_notices || [])
    end
  end

  private

  attr_reader :employee, :attributes, :actor

  def authorize!
    raise Error, "Only a super admin can transition W-2/1099 classification" unless actor&.super_admin?
  end

  def validate_transition!
    raise Error, "Only an active worker record can be transitioned" unless employee.active?
    raise Error, "This worker already has a successor record" if employee.next_employee.present?
    raise Error, "Employment type is invalid" unless Employee::EMPLOYMENT_TYPES.include?(target_employment_type)
    if employee.tax_classification == target_tax_classification
      raise Error, "The new record must cross the W-2/1099 classification boundary"
    end
    raise Error, "Effective date cannot be in the future" if effective_date > PayrollBusinessClock.today
    if employee.hire_date.present? && effective_date <= employee.hire_date
      raise Error, "Effective date must be after the current record's start date"
    end
    raise Error, "Reason must be at least 10 characters" if reason.length < 10
    if pay_rate.negative? || (pay_rate.zero? && !variable_salary_target?)
      raise Error, "Pay rate must be greater than 0"
    end

    conflicting_periods = employee.payroll_items
      .joins(:pay_period)
      .where("pay_periods.pay_date >= ?", effective_date)
      .distinct
      .count(:pay_period_id)

    return if conflicting_periods.zero?

    raise Error,
          "#{conflicting_periods} payroll period(s) on or after the effective date still use this record; " \
          "resolve them before transitioning"
  end

  def target_employment_type
    @target_employment_type ||= attributes[:employment_type].to_s
  end

  def target_tax_classification
    target_employment_type == "contractor" ? "1099" : "w2"
  end

  def effective_date
    @effective_date ||= Date.iso8601(attributes[:effective_date].to_s)
  rescue Date::Error
    raise Error, "Effective date is invalid"
  end

  def reason
    @reason ||= attributes[:reason].to_s.strip
  end

  def new_employee_attributes
    shared_identity_attributes.merge(
      previous_employee: employee,
      employment_type: target_employment_type,
      pay_rate: pay_rate,
      pay_frequency: attributes[:pay_frequency].presence || employee.pay_frequency,
      hire_date: effective_date,
      status: "active",
      termination_date: nil,
      default_custom_earnings: [],
      default_payroll_adjustments: []
    ).merge(target_classification_attributes)
  end

  def shared_identity_attributes
    attrs = employee.attributes.symbolize_keys.slice(
      :company_id,
      :department_id,
      :first_name,
      :middle_name,
      :last_name,
      :email,
      :ssn_encrypted,
      :date_of_birth,
      :address_line1,
      :address_line2,
      :city,
      :state,
      :zip,
      :phone,
      :contact_source
    )
    attrs[:email] = attributes[:email] if attributes.key?(:email)
    attrs[:phone] = attributes[:phone] if attributes.key?(:phone)
    attrs[:email_verified_at] = nil
    attrs[:phone_confirmed_by_employee_at] = nil
    attrs
  end

  # Current account links always come first. Evidence that this employee and
  # address were accepted before (a verified email, or a recorded same-person
  # confirmation) can only waive asking for that confirmation again; a login
  # now linked to another worker, or links that can't be checked, still win.
  # A copied email that can't be used is left blank with a notice for the
  # operator instead of blocking the change. An edited email gets every check.
  CURRENT_LINK_REJECTIONS = %w[linked_to_other_employee link_check_unavailable].freeze

  def validate_contact_details!(new_employee)
    email_unchanged = EmployeeContactValidator.normalize_email(new_employee.email) == EmployeeContactValidator.normalize_email(employee.email)
    result = run_contact_validator(new_employee, check_login_identity: true)
    if email_unchanged && result.errors[:email].present?
      if previously_accepted_email? && !CURRENT_LINK_REJECTIONS.include?(result.login_email_rejection_reason)
        result = run_contact_validator(new_employee, check_login_identity: false)
      end
      if result.errors[:email].present?
        new_employee.email = nil
        (@contact_notices ||= []) << BLANKED_EMAIL_NOTICE
        result = run_contact_validator(new_employee, check_login_identity: true)
      end
    end
    return result if result.valid?

    result.apply_errors_to(new_employee)
    raise EmployeeContactValidator::ValidationError.new(result: result, record: new_employee)
  end

  def run_contact_validator(new_employee, check_login_identity:)
    EmployeeContactValidator.call(
      employee: new_employee,
      company: employee.company,
      email: new_employee.email,
      phone: new_employee.phone,
      check_login_identity: check_login_identity,
      confirm_same_person_email: attributes[:confirm_same_person_email],
      actor: actor,
      source: "staff",
      exclude_employee_ids: [ employee.id ]
    )
  end

  def previously_accepted_email?
    email = EmployeeContactValidator.normalize_email(employee.email)
    return false if email.blank?
    return true if employee.email_verified_at.present?

    AuditLog.where(company_id: employee.company_id, record_type: "employees", record_id: employee.id,
      action: "employees#confirm_same_person_email")
      .where("LOWER(TRIM(metadata->>'email')) = ?", email)
      .exists?
  end

  def apply_validated_contact_details!(new_employee, contact_result)
    new_employee.email = contact_result.normalized_email
    new_employee.phone = contact_result.normalized_phone
    new_employee.email_verified_at = nil
    new_employee.phone_confirmed_by_employee_at = nil
    new_employee.contact_source = "staff" if attributes.key?(:email) || attributes.key?(:phone)
  end

  def target_classification_attributes
    if target_employment_type == "contractor"
      {
        contractor_type: attributes[:contractor_type].presence || "individual",
        contractor_pay_type: attributes[:contractor_pay_type].presence || "flat_fee",
        business_name: attributes[:business_name].presence,
        contractor_ein: attributes[:contractor_ein].presence,
        w9_on_file: false,
        salary_type: "annual",
        retirement_rate: 0,
        roth_retirement_rate: 0,
        employer_retirement_match_rate: 0,
        employer_roth_match_rate: 0
      }.tap do |contractor_attributes|
        contractor_attributes[:ssn_encrypted] = nil if contractor_attributes[:contractor_type] == "business"
      end
    else
      {
        ssn_encrypted: attributes[:ssn].presence,
        ssn_confirmation: attributes[:ssn_confirmation],
        require_ssn_confirmation: true,
        salary_type: target_employment_type == "salary" ? attributes[:salary_type].presence || "annual" : "annual",
        filing_status: attributes[:filing_status].presence || "single",
        allowances: 0,
        additional_withholding: 0,
        w4_dependent_credit: 0,
        w4_step2_multiple_jobs: false,
        w4_step4a_other_income: 0,
        w4_step4b_deductions: 0,
        w4_form_version: Employee::MIN_SUPPORTED_W4_FORM_VERSION,
        w4_effective_on: effective_date,
        retirement_rate: 0,
        roth_retirement_rate: 0,
        employer_retirement_match_rate: 0,
        employer_roth_match_rate: 0,
        business_name: nil,
        contractor_ein: nil,
        w9_on_file: false
      }
    end
  end

  def create_primary_wage_rate!(new_employee)
    uses_hourly_rate = new_employee.hourly? || new_employee.contractor_hourly?
    return unless uses_hourly_rate

    new_employee.employee_wage_rates.create!(
      label: "Regular",
      rate: new_employee.pay_rate,
      is_primary: true,
      active: true
    )
  end

  def create_w4_election!(new_employee)
    return if new_employee.contractor?

    EmployeeW4ElectionChangeService.new(
      employee: new_employee,
      attributes: EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| new_employee.public_send(attribute) },
      actor: actor,
      source: "employee_creation",
      reason: "Initial W-4 election for tax-classification transition"
    ).call!
  end

  def pay_rate
    @pay_rate ||= BigDecimal(attributes[:pay_rate].to_s)
  rescue ArgumentError
    raise Error, "Pay rate is invalid"
  end

  def variable_salary_target?
    target_employment_type == "salary" && attributes[:salary_type].to_s == "variable"
  end
end
