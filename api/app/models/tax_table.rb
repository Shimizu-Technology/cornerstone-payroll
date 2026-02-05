# frozen_string_literal: true

class TaxTable < ApplicationRecord
  validates :tax_year, presence: true
  validates :filing_status, presence: true, inclusion: { in: %w[single married head_of_household] }
  validates :pay_frequency, presence: true, inclusion: { in: %w[biweekly weekly semimonthly monthly] }
  validates :bracket_data, presence: true
  validates :ss_rate, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :ss_wage_base, presence: true, numericality: { greater_than: 0 }
  validates :medicare_rate, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  validates :tax_year, uniqueness: { scope: [ :filing_status, :pay_frequency ] }

  scope :for_year, ->(year) { where(tax_year: year) }
  scope :for_filing_status, ->(status) { where(filing_status: status) }
  scope :for_pay_frequency, ->(frequency) { where(pay_frequency: frequency) }

  # Find the appropriate tax table
  def self.find_table(tax_year:, filing_status:, pay_frequency:)
    find_by!(tax_year: tax_year, filing_status: filing_status, pay_frequency: pay_frequency)
  end

  # Get bracket array with symbolized keys
  def brackets
    bracket_data.map(&:deep_symbolize_keys)
  end

  # Find the applicable bracket for a given income
  def find_bracket(income)
    brackets.find do |bracket|
      income >= bracket[:min_income] && income <= bracket[:max_income]
    end
  end
end
