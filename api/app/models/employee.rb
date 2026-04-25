# frozen_string_literal: true

class Employee < ApplicationRecord
  EMPLOYMENT_TYPES = %w[hourly salary contractor].freeze
  SALARY_TYPES = %w[annual per_period variable].freeze
  CONTRACTOR_TYPES = %w[individual business].freeze
  CONTRACTOR_PAY_TYPES = %w[hourly flat_fee].freeze
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
    loans: :loan_payment
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
    loans: "COALESCE(SUM(loan_payment), 0)"
  }.freeze

  belongs_to :company
  belongs_to :department, optional: true
  has_many :payroll_items, dependent: :destroy
  has_many :employee_deductions, dependent: :destroy
  has_many :deduction_types, through: :employee_deductions
  has_many :employee_ytd_totals, dependent: :destroy
  has_many :employee_loans, dependent: :destroy
  has_many :employee_wage_rates, dependent: :destroy

  before_validation :normalize_pay_rate_precision

  # Encrypt sensitive fields
  encrypts :ssn_encrypted, deterministic: true
  encrypts :bank_routing_number_encrypted
  encrypts :bank_account_number_encrypted

  validates :first_name, presence: true
  validates :last_name, presence: true
  validates :pay_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :employment_type, inclusion: { in: EMPLOYMENT_TYPES }
  validates :pay_frequency, inclusion: { in: %w[biweekly weekly semimonthly monthly] }
  validates :status, inclusion: { in: %w[active inactive terminated] }
  validates :salary_type, inclusion: { in: SALARY_TYPES }, if: :salary?
  validates :contractor_type, inclusion: { in: CONTRACTOR_TYPES }, if: :contractor?
  validates :contractor_pay_type, inclusion: { in: CONTRACTOR_PAY_TYPES }, if: :contractor?

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
  end

  scope :active, -> { where(status: "active") }
  scope :hourly, -> { where(employment_type: "hourly") }
  scope :salary, -> { where(employment_type: "salary") }
  scope :contractor, -> { where(employment_type: "contractor") }
  scope :w2_employees, -> { where(employment_type: %w[hourly salary]) }

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
    [ address_line1, address_line2, "#{city}, #{state} #{zip}" ].compact_blank.join("\n")
  end

  def active?
    status == "active"
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

  def contractor_hourly?
    contractor? && contractor_pay_type == "hourly"
  end

  def contractor_flat_fee?
    contractor? && contractor_pay_type == "flat_fee"
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

    select_list = YTD_AGGREGATE_COLUMNS.map { |key, sql| "#{sql} AS #{key}" }.join(", ")
    row = self.class.connection.select_one(scope.reselect(Arel.sql(select_list)).to_sql) || {}

    YTD_AGGREGATE_SOURCE_COLUMNS.keys.each_with_object({}) do |key, totals|
      totals[key] = row[key.to_s].to_f
    end
  end

  def pay_date_range_for_year(year)
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end

  def normalize_pay_rate_precision
    self.pay_rate = round_currency_value(pay_rate)
  end

  def round_currency_value(value)
    return value if value.nil?

    BigDecimal(value.to_s).round(2)
  end
end
