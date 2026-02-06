# frozen_string_literal: true

class Employee < ApplicationRecord
  belongs_to :company
  belongs_to :department, optional: true
  has_many :payroll_items, dependent: :destroy
  has_many :employee_deductions, dependent: :destroy
  has_many :deduction_types, through: :employee_deductions
  has_many :employee_ytd_totals, dependent: :destroy

  # Encrypt sensitive fields
  encrypts :ssn_encrypted, deterministic: true
  encrypts :bank_routing_number_encrypted
  encrypts :bank_account_number_encrypted

  validates :first_name, presence: true
  validates :last_name, presence: true
  validates :pay_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :employment_type, inclusion: { in: %w[hourly salary] }
  validates :pay_frequency, inclusion: { in: %w[biweekly weekly semimonthly monthly] }
  validates :status, inclusion: { in: %w[active inactive terminated] }
  validates :filing_status, inclusion: { in: %w[single married married_separate head_of_household] }
  validates :allowances, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :retirement_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :roth_retirement_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  scope :active, -> { where(status: "active") }
  scope :hourly, -> { where(employment_type: "hourly") }
  scope :salary, -> { where(employment_type: "salary") }

  def full_name
    [ first_name, middle_name, last_name ].compact_blank.join(" ")
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

  # Get YTD totals for a given year
  def ytd_totals_for(year)
    employee_ytd_totals.find_or_create_by(year: year)
  end

  # Calculate YTD gross from payroll items
  def calculate_ytd_gross(year)
    payroll_items
      .joins(:pay_period)
      .where(pay_periods: { status: "committed", pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31) })
      .sum(:gross_pay)
  end

  # Calculate YTD Social Security tax withheld
  def calculate_ytd_social_security(year)
    payroll_items
      .joins(:pay_period)
      .where(pay_periods: { status: "committed", pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31) })
      .sum(:social_security_tax)
  end

  # Returns last 4 digits of SSN for display purposes
  def ssn_last_four
    return nil if ssn_encrypted.blank?
    # Remove any non-digit characters and get last 4
    ssn_encrypted.to_s.gsub(/\D/, "").last(4).presence
  end
end
