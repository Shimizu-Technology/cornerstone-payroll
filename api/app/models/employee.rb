# frozen_string_literal: true

class Employee < ApplicationRecord
  EMPLOYMENT_TYPES = %w[hourly salary contractor].freeze
  SALARY_TYPES = %w[annual variable].freeze
  CONTRACTOR_TYPES = %w[individual business].freeze
  CONTRACTOR_PAY_TYPES = %w[hourly flat_fee].freeze

  belongs_to :company
  belongs_to :department, optional: true
  has_many :payroll_items, dependent: :destroy
  has_many :employee_deductions, dependent: :destroy
  has_many :deduction_types, through: :employee_deductions
  has_many :employee_ytd_totals, dependent: :destroy
  has_many :employee_loans, dependent: :destroy
  has_many :employee_wage_rates, dependent: :destroy

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

  attr_writer :cached_ytd_gross, :cached_ytd_social_security

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

  # Calculate YTD gross from payroll items.
  # Returns the precomputed cache when set by batch operations (e.g. run_payroll).
  def calculate_ytd_gross(year)
    return @cached_ytd_gross if defined?(@cached_ytd_gross) && @cached_ytd_gross

    payroll_items
      .joins(:pay_period)
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
          .where(company_id: company_id, pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
          .select(:id)
      })
      .sum(:gross_pay)
  end

  # Calculate YTD Social Security tax withheld.
  # Returns the precomputed cache when set by batch operations.
  def calculate_ytd_social_security(year)
    return @cached_ytd_social_security if defined?(@cached_ytd_social_security) && @cached_ytd_social_security

    payroll_items
      .joins(:pay_period)
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
          .where(company_id: company_id, pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
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
end
