# frozen_string_literal: true

class EmployeeClassificationTransitionService
  class Error < StandardError; end

  Result = Struct.new(:previous_employee, :new_employee, keyword_init: true)

  def initialize(employee:, attributes:, actor:)
    @employee = employee
    @attributes = attributes.to_h.deep_symbolize_keys
    @actor = actor
  end

  def call
    authorize!

    Employee.transaction do
      employee.lock!
      validate_transition!

      new_employee = Employee.create!(new_employee_attributes)
      create_primary_wage_rate!(new_employee)

      employee.update!(
        status: "terminated",
        termination_date: effective_date - 1.day
      )

      AuditLog.record!(
        user: actor,
        company_id: employee.company_id,
        action: "employees#transition_tax_classification",
        record_type: "employees",
        record_id: new_employee.id,
        subject_name: new_employee.display_name,
        metadata: {
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
      )

      Result.new(previous_employee: employee.reload, new_employee: new_employee.reload)
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
    raise Error, "Effective date cannot be in the future" if effective_date > Date.current
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
    employee.attributes.symbolize_keys.slice(
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
      :phone
    )
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

  def pay_rate
    @pay_rate ||= BigDecimal(attributes[:pay_rate].to_s)
  rescue ArgumentError
    raise Error, "Pay rate is invalid"
  end

  def variable_salary_target?
    target_employment_type == "salary" && attributes[:salary_type].to_s == "variable"
  end
end
