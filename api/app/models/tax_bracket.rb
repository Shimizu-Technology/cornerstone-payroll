# frozen_string_literal: true

# Stores a single tax bracket within a filing status config.
# There are typically 7 brackets per filing status (10%, 12%, 22%, 24%, 32%, 35%, 37%).
class TaxBracket < ApplicationRecord
  belongs_to :filing_status_config

  validates :bracket_order, presence: true, 
            numericality: { only_integer: true, greater_than: 0 }
  validates :bracket_order, uniqueness: { scope: :filing_status_config_id }
  validates :min_income, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :max_income, numericality: { greater_than: 0, allow_nil: true }
  validates :rate, presence: true, numericality: { greater_than_or_equal_to: 0, less_than: 1 }

  # Calculate per-period thresholds
  def min_income_per_period(periods_per_year)
    (min_income / periods_per_year).round(2)
  end

  def max_income_per_period(periods_per_year)
    return nil if max_income.nil?
    (max_income / periods_per_year).round(2)
  end
end
