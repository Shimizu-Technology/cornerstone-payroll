# frozen_string_literal: true

class Employee < ApplicationRecord
  include PayrollAdjustable
  attr_accessor :ssn_confirmation, :require_ssn_confirmation, :allow_tax_classification_change

  EMPLOYMENT_TYPES = %w[hourly salary contractor].freeze
  SALARY_TYPES = %w[annual per_period variable].freeze
  CONTRACTOR_TYPES = %w[individual business].freeze
  CONTRACTOR_PAY_TYPES = %w[hourly flat_fee].freeze
  MIN_SUPPORTED_W4_FORM_VERSION = 2020
  LEGACY_SOCIAL_SECURITY_RATE = BigDecimal("0.062")
  YTD_AGGREGATE_SOURCE_COLUMNS = {
    gross_pay: :gross_pay,
    net_pay: :net_pay,
    withholding_tax: :withholding_tax,
    social_security_tax: :social_security_tax,
    medicare_tax: :medicare_tax,
    additional_withholding: :additional_withholding,
    retirement: :retirement_payment,
    roth_retirement: :roth_retirement_payment,
    insurance: :insurance_payment,
    loans: :loan_payment,
    tips_paid_out: :tips_paid_out,
    social_security_taxable_total: :social_security_taxable_total,
    medicare_taxable_wages: :medicare_taxable_wages
  }.freeze
  YTD_AGGREGATE_COLUMNS = {
    gross_pay: "COALESCE(SUM(gross_pay), 0)",
    net_pay: "COALESCE(SUM(net_pay), 0)",
    withholding_tax: "COALESCE(SUM(withholding_tax), 0)",
    social_security_tax: "COALESCE(SUM(social_security_tax), 0)",
    medicare_tax: "COALESCE(SUM(medicare_tax), 0)",
    additional_withholding: "COALESCE(SUM(additional_withholding), 0)",
    retirement: "COALESCE(SUM(retirement_payment), 0)",
    roth_retirement: "COALESCE(SUM(roth_retirement_payment), 0)",
    insurance: "COALESCE(SUM(insurance_payment), 0)",
    loans: "COALESCE(SUM(loan_payment), 0)",
    tips_paid_out: "COALESCE(SUM(tips_paid_out), 0)",
    social_security_taxable_total: "COALESCE(SUM(COALESCE(social_security_taxable_wages + social_security_taxable_tips, gross_pay)), 0)",
    medicare_taxable_wages: "COALESCE(SUM(COALESCE(medicare_taxable_wages, gross_pay)), 0)"
  }.freeze

  def self.social_security_rate_for_year(year)
    AnnualTaxConfig.for_year(year)&.ss_rate&.to_d ||
      TaxTable.for_year(year).where.not(ss_rate: nil).pick(:ss_rate)&.to_d ||
      LEGACY_SOCIAL_SECURITY_RATE
  end

  def self.ytd_aggregate_columns_for_year(year)
    rate = connection.quote(social_security_rate_for_year(year))
    YTD_AGGREGATE_COLUMNS.merge(
      social_security_taxable_total: <<~SQL.squish
        COALESCE(SUM(
          CASE
            WHEN social_security_taxable_wages IS NOT NULL
             AND social_security_taxable_tips IS NOT NULL
              THEN social_security_taxable_wages + social_security_taxable_tips
            ELSE social_security_tax / NULLIF(#{rate}, 0)
          END
        ), 0)
      SQL
    )
  end

  belongs_to :company
  belongs_to :department, optional: true
  belongs_to :previous_employee,
             class_name: "Employee",
             optional: true,
             inverse_of: :next_employee
  has_one :next_employee,
          class_name: "Employee",
          foreign_key: :previous_employee_id,
          inverse_of: :previous_employee,
          dependent: :restrict_with_error
  has_many :payroll_items, dependent: :destroy
  has_many :pay_period_excluded_employees, dependent: :destroy
  has_many :employee_deductions, dependent: :destroy
  has_many :deduction_types, through: :employee_deductions
  has_many :employee_payroll_fields, dependent: :destroy
  has_many :payroll_field_definitions, through: :employee_payroll_fields
  has_many :employee_ytd_totals, dependent: :destroy
  has_many :employee_loans, dependent: :destroy
  has_many :employee_wage_rates, dependent: :destroy
  has_many :employee_tipped_occupations, dependent: :destroy
  has_many :employee_work_profiles, dependent: :restrict_with_error
  has_many :employee_status_events, dependent: :restrict_with_error
  has_many :daily_time_records, dependent: :restrict_with_error
  has_many :payroll_time_allocations, dependent: :restrict_with_error
  has_many :employee_change_requests, dependent: :restrict_with_error

  before_validation :normalize_pay_rate_precision
  before_validation :normalize_filing_status_value
  before_validation :normalize_w4_currency_precision
  before_validation :normalize_default_payroll_adjustments

  # Encrypt sensitive fields
  encrypts :ssn_encrypted, deterministic: true
  encrypts :bank_routing_number_encrypted
  encrypts :bank_account_number_encrypted

  validates :first_name, presence: true
  validates :last_name, presence: true
  validates :pay_rate,
            presence: true,
            numericality: { greater_than_or_equal_to: 0, less_than: 1_000_000_000_000 }
  validates :employment_type, inclusion: { in: EMPLOYMENT_TYPES }
  validates :pay_frequency, inclusion: { in: %w[biweekly weekly semimonthly monthly] }
  validates :status, inclusion: { in: %w[active inactive terminated] }
  validates :salary_type, inclusion: { in: SALARY_TYPES }, if: :salary?
  validates :contractor_type, inclusion: { in: CONTRACTOR_TYPES }, if: :contractor?
  validates :contractor_pay_type, inclusion: { in: CONTRACTOR_PAY_TYPES }, if: :contractor?
  validate :required_filing_fields, if: :filing_data_validation_required?
  validate :filing_ssn_format, if: -> { filing_data_validation_required? && filing_ssn_required? }
  validate :business_ein_format, if: -> { filing_data_validation_required? && business_contractor? }
  validate :matching_ssn_confirmation, if: :ssn_confirmation_required?
  validate :tax_classification_cannot_change_in_place, on: :update
  validate :previous_employee_transition_is_valid
  validate :portal_pending_employee_is_inactive

  # W-2 employee validations (not applicable to contractors)
  with_options unless: :contractor? do
    validates :filing_status, inclusion: { in: %w[single married married_separate head_of_household] }
    validates :allowances, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :retirement_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :roth_retirement_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :employer_retirement_match_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :employer_roth_match_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :w4_dependent_credit, numericality: { greater_than_or_equal_to: 0 }
    validates :w4_step4a_other_income, numericality: { greater_than_or_equal_to: 0 }
    validates :w4_step4b_deductions, numericality: { greater_than_or_equal_to: 0 }
    validates :w4_form_version, numericality: { only_integer: true, greater_than_or_equal_to: 1987, less_than_or_equal_to: ->(_) { Date.current.year + 1 } }
  end

  scope :active, -> { where(status: "active") }
  scope :hourly, -> { where(employment_type: "hourly") }
  scope :salary, -> { where(employment_type: "salary") }
  scope :contractor, -> { where(employment_type: "contractor") }
  scope :w2_employees, -> { where(employment_type: %w[hourly salary]) }
  scope :eligible_for_period, ->(period_start, period_end) {
    where("hire_date IS NULL OR hire_date <= ?", period_end)
      .where("termination_date IS NULL OR termination_date >= ?", period_start)
      .where(status: %w[active terminated])
      .where(
        <<~SQL.squish,
          NOT EXISTS (
            SELECT 1
            FROM employee_status_events termination_events
            WHERE termination_events.employee_id = employees.id
              AND termination_events.event_type = 'terminated'
              AND termination_events.effective_date < :period_start
              AND NOT EXISTS (
                SELECT 1
                FROM employee_status_events reactivation_events
                WHERE reactivation_events.employee_id = employees.id
                  AND reactivation_events.event_type = 'reactivated'
                  AND reactivation_events.effective_date > termination_events.effective_date
                  AND reactivation_events.effective_date <= :period_end
              )
          )
        SQL
        period_start: period_start,
        period_end: period_end
      )
  }

  def active_wage_rates
    if association(:employee_wage_rates).loaded?
      employee_wage_rates.select(&:active?).sort_by { |rate| [ rate.is_primary ? 0 : 1, rate.label.to_s ] }
    else
      employee_wage_rates.active.order(is_primary: :desc, label: :asc)
    end
  end

  def primary_wage_rate
    rates = active_wage_rates
    rates.find(&:is_primary) || rates.first
  end

  def full_name
    [ first_name, middle_name, last_name ].compact_blank.join(" ")
  end

  def display_name
    contractor? && business_name.present? ? "#{full_name} (#{business_name})" : full_name
  end

  def full_address
    city_state_zip = [
      city.presence,
      state.presence,
      zip.presence
    ].compact

    city_state_zip_line = if city_state_zip.empty?
      nil
    elsif city.present? && state.present?
      [ "#{city}, #{state}", zip.presence ].compact.join(" ")
    else
      city_state_zip.join(" ")
    end

    [ address_line1, address_line2, city_state_zip_line ].compact_blank.join("\n")
  end

  def active?
    status == "active"
  end

  def eligible_on?(date)
    date = date.to_date
    return false if hire_date.present? && date < hire_date

    event = employee_status_events.where("effective_date <= ?", date).order(effective_date: :desc, id: :desc).first
    return event.resulting_status == "active" if event

    status != "inactive" && (termination_date.blank? || date <= termination_date)
  end

  def work_profile_on(date)
    employee_work_profiles.effective_on(date).first
  end

  def hourly?
    employment_type == "hourly"
  end

  def salary?
    employment_type == "salary"
  end

  def variable_salary?
    salary? && salary_type == "variable"
  end

  def contractor?
    employment_type == "contractor"
  end

  def w2_employee?
    hourly? || salary?
  end

  def tax_classification
    contractor? ? "1099" : "w2"
  end

  def contractor_hourly?
    contractor? && contractor_pay_type == "hourly"
  end

  def contractor_flat_fee?
    contractor? && contractor_pay_type == "flat_fee"
  end

  def business_contractor?
    contractor? && contractor_type == "business"
  end

  def individual_filer?
    !business_contractor?
  end

  def normalized_filing_status
    FilingStatusConfig.normalize(filing_status)
  end

  def supported_w4_form_version?
    w4_form_version.to_i >= MIN_SUPPORTED_W4_FORM_VERSION
  end

  # TIN for 1099-NEC: EIN for business entities, SSN for individuals
  def tax_identification_number
    contractor? && contractor_type == "business" && contractor_ein.present? ? contractor_ein : ssn_encrypted
  end

  # Get YTD totals for a given year
  def ytd_totals_for(year)
    employee_ytd_totals.find_or_create_by(year: year)
  end

  def cache_ytd_values!(year:, as_of_pay_date:, before_pay_period_id:, totals:)
    normalized_totals = YTD_AGGREGATE_SOURCE_COLUMNS.keys.each_with_object({}) do |key, acc|
      acc[key] = totals[key].to_f
    end

    @cached_ytd_before_totals = normalized_totals
    @cached_ytd_gross = normalized_totals[:gross_pay]
    @cached_ytd_social_security = normalized_totals[:social_security_tax]
    @cached_ytd_year = year
    @cached_ytd_as_of_pay_date = as_of_pay_date
    @cached_ytd_before_pay_period_id = before_pay_period_id
  end

  def cached_ytd_snapshot
    {
      gross: defined?(@cached_ytd_gross) ? @cached_ytd_gross : nil,
      social_security: defined?(@cached_ytd_social_security) ? @cached_ytd_social_security : nil,
      before_totals: defined?(@cached_ytd_before_totals) ? @cached_ytd_before_totals&.dup : nil,
      year: defined?(@cached_ytd_year) ? @cached_ytd_year : nil,
      as_of_pay_date: defined?(@cached_ytd_as_of_pay_date) ? @cached_ytd_as_of_pay_date : nil,
      before_pay_period_id: defined?(@cached_ytd_before_pay_period_id) ? @cached_ytd_before_pay_period_id : nil
    }
  end

  def restore_cached_ytd_snapshot!(snapshot)
    restore_cached_ytd_ivar(:@cached_ytd_gross, snapshot[:gross])
    restore_cached_ytd_ivar(:@cached_ytd_social_security, snapshot[:social_security])
    restore_cached_ytd_ivar(:@cached_ytd_before_totals, snapshot[:before_totals])
    restore_cached_ytd_ivar(:@cached_ytd_year, snapshot[:year])
    restore_cached_ytd_ivar(:@cached_ytd_as_of_pay_date, snapshot[:as_of_pay_date])
    restore_cached_ytd_ivar(:@cached_ytd_before_pay_period_id, snapshot[:before_pay_period_id])
  end

  def ytd_totals_before(year:, pay_date:, pay_period_id:)
    if cached_ytd_matches?(year, pay_date, pay_period_id) &&
       defined?(@cached_ytd_before_totals) && @cached_ytd_before_totals.present?
      return @cached_ytd_before_totals.dup
    end

    ytd_aggregate_totals(
      year: year,
      pay_date: pay_date,
      pay_period_id: pay_period_id,
      include_current_period: false
    )
  end

  def ytd_totals_through(year:, pay_date:, pay_period_id:)
    # This intentionally bypasses the pre-period cache because "through"
    # totals are used for display/rendering and must include the current
    # pay period's own row in the aggregate window.
    ytd_aggregate_totals(
      year: year,
      pay_date: pay_date,
      pay_period_id: pay_period_id,
      include_current_period: true
    )
  end

  def ytd_totals_for_scope(scope, tax_year:)
    columns = self.class.ytd_aggregate_columns_for_year(tax_year)
    select_list = columns.map { |key, sql| "#{sql} AS #{key}" }.join(", ")
    row = self.class.connection.select_one(scope.reselect(Arel.sql(select_list)).to_sql) || {}

    columns.keys.each_with_object({}) do |key, totals|
      totals[key] = row[key.to_s].to_f
    end
  end

  # Calculate YTD gross from payroll items.
  # Returns the precomputed cache when set by batch operations (e.g. run_payroll).
  def calculate_ytd_gross(year, as_of_pay_date: nil, before_pay_period_id: nil)
    if cached_ytd_matches?(year, as_of_pay_date, before_pay_period_id) &&
       defined?(@cached_ytd_gross) && !@cached_ytd_gross.nil?
      return @cached_ytd_gross
    end

    if as_of_pay_date.present? && before_pay_period_id.present?
      return ytd_totals_before(year: year, pay_date: as_of_pay_date, pay_period_id: before_pay_period_id)[:gross_pay]
    end

    payroll_items
      .joins(:pay_period)
      .not_voided
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
          .where(company_id: company_id, pay_date: pay_date_range_for_year(year))
          .select(:id)
      })
      .sum(:gross_pay)
  end

  # Calculate YTD Social Security tax withheld.
  # Returns the precomputed cache when set by batch operations.
  def calculate_ytd_social_security(year, as_of_pay_date: nil, before_pay_period_id: nil)
    if cached_ytd_matches?(year, as_of_pay_date, before_pay_period_id) &&
       defined?(@cached_ytd_social_security) && !@cached_ytd_social_security.nil?
      return @cached_ytd_social_security
    end

    if as_of_pay_date.present? && before_pay_period_id.present?
      return ytd_totals_before(year: year, pay_date: as_of_pay_date, pay_period_id: before_pay_period_id)[:social_security_tax]
    end

    payroll_items
      .joins(:pay_period)
      .not_voided
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
          .where(company_id: company_id, pay_date: pay_date_range_for_year(year))
          .select(:id)
      })
      .sum(:social_security_tax)
  end

  # Returns last 4 digits of SSN for display purposes
  def ssn_digits
    return nil if ssn_encrypted.blank?

    ssn_encrypted.to_s.gsub(/\D/, "").presence
  end

  def ssn_last_four
    ssn_digits&.last(4)
  end

  def valid_filing_ssn?
    ssn_digits&.length == 9
  end

  private

  def tax_classification_cannot_change_in_place
    return unless will_save_change_to_employment_type?
    return if ActiveModel::Type::Boolean.new.cast(allow_tax_classification_change)

    prior_type = employment_type_in_database
    return if prior_type.blank?
    return if (prior_type == "contractor") == contractor?

    errors.add(
      :employment_type,
      "cannot change between W-2 and 1099 in place; create a new worker record"
    )
  end

  def previous_employee_transition_is_valid
    return if previous_employee.blank?

    errors.add(:previous_employee, "must belong to the same company") if previous_employee.company_id != company_id
    errors.add(:previous_employee, "cannot reference itself") if persisted? && previous_employee_id == id
    if previous_employee.tax_classification == tax_classification
      errors.add(:previous_employee, "must use the opposite W-2/1099 classification")
    end
  end

  def required_filing_fields
    {
      hire_date: hire_date,
      address_line1: address_line1,
      city: city,
      state: state,
      zip: zip
    }.each do |field, value|
      errors.add(field, "can't be blank") if value.blank?
    end

    if business_contractor?
      errors.add(:business_name, "can't be blank") if business_name.blank?
      errors.add(:contractor_ein, "can't be blank") if contractor_ein.blank?
    elsif ssn_encrypted.blank?
      errors.add(:ssn, "can't be blank")
    end
  end

  def filing_data_validation_required?
    return false if portal_pending_approval?
    return true if new_record?

    (changes_to_save.keys - %w[status termination_date updated_at]).any?
  end

  def portal_pending_employee_is_inactive
    return unless portal_pending_approval?
    return if status == "inactive"

    errors.add(:status, "must be inactive while client-submitted payroll details await approval")
  end

  def filing_ssn_format
    return if ssn_encrypted.blank?
    return if valid_filing_ssn?

    errors.add(:ssn, "must contain exactly 9 digits")
  end

  def filing_ssn_required?
    individual_filer?
  end

  def business_ein_format
    return if contractor_ein.blank?
    return if contractor_ein.to_s.gsub(/\D/, "").length == 9

    errors.add(:contractor_ein, "must contain exactly 9 digits")
  end

  def ssn_confirmation_required?
    ActiveModel::Type::Boolean.new.cast(require_ssn_confirmation) && individual_filer?
  end

  def matching_ssn_confirmation
    if ssn_confirmation.blank?
      errors.add(:ssn_confirmation, "can't be blank")
    elsif ssn_digits != ssn_confirmation.to_s.gsub(/\D/, "")
      errors.add(:ssn_confirmation, "does not match Social Security Number")
    end
  end

  def normalize_filing_status_value
    self.filing_status = normalized_filing_status if filing_status.present?
  end

  def normalize_default_payroll_adjustments
    self.default_payroll_adjustments = self.class.normalize_payroll_adjustments(default_payroll_adjustments)
  end

  def cached_ytd_matches?(year, as_of_pay_date, before_pay_period_id)
    if as_of_pay_date.nil? && before_pay_period_id.nil?
      return !defined?(@cached_ytd_year) || @cached_ytd_year.nil? || @cached_ytd_year == year
    end

    defined?(@cached_ytd_year) &&
      @cached_ytd_year == year &&
      defined?(@cached_ytd_as_of_pay_date) &&
      @cached_ytd_as_of_pay_date == as_of_pay_date &&
      defined?(@cached_ytd_before_pay_period_id) &&
      @cached_ytd_before_pay_period_id == before_pay_period_id
  end

  def restore_cached_ytd_ivar(name, value)
    if value.nil?
      remove_instance_variable(name) if instance_variable_defined?(name)
    else
      instance_variable_set(name, value)
    end
  end

  def ytd_aggregate_totals(year:, pay_date:, pay_period_id:, include_current_period:)
    scope = payroll_items
      .joins(:pay_period)
      .not_voided
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
          .where(company_id: company_id, pay_date: pay_date_range_for_year(year))
          .select(:id)
      })

    comparator = include_current_period ? "<=" : "<"
    scope = scope.where(
      "(pay_periods.pay_date < ?) OR (pay_periods.pay_date = ? AND pay_periods.id #{comparator} ?)",
      pay_date, pay_date, pay_period_id
    )

    ytd_totals_for_scope(scope, tax_year: year)
  end

  def pay_date_range_for_year(year)
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end

  def normalize_pay_rate_precision
    self.pay_rate = round_currency_value(pay_rate)
  end

  def normalize_w4_currency_precision
    self.additional_withholding = round_currency_value(additional_withholding)
    self.w4_dependent_credit = round_currency_value(w4_dependent_credit)
    self.w4_step4a_other_income = round_currency_value(w4_step4a_other_income)
    self.w4_step4b_deductions = round_currency_value(w4_step4b_deductions)
  end

  def round_currency_value(value)
    return value if value.nil?

    BigDecimal(value.to_s).round(2)
  end
end
