# frozen_string_literal: true

# Stores standard deduction for a specific filing status within a tax year.
class FilingStatusConfig < ApplicationRecord
  FILING_STATUSES = %w[single married head_of_household].freeze

  belongs_to :annual_tax_config
  has_many :tax_brackets, -> { order(:bracket_order) }, dependent: :destroy

  validates :filing_status, presence: true, inclusion: { in: FILING_STATUSES }
  validates :filing_status, uniqueness: { scope: :annual_tax_config_id }
  validates :standard_deduction, presence: true, numericality: { greater_than_or_equal_to: 0 }

  # Calculate per-period standard deduction
  def standard_deduction_per_period(periods_per_year)
    (standard_deduction / periods_per_year).round(2)
  end

  # Get all brackets for this filing status
  def brackets_array
    tax_brackets.map do |b|
      {
        min_income: b.min_income,
        max_income: b.max_income,
        rate: b.rate
      }
    end
  end
end
