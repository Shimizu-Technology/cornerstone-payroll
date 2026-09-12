# frozen_string_literal: true

class AnnualRetirementLimit < ApplicationRecord
  validates :tax_year, inclusion: { in: 2000..2200 }, uniqueness: true
  validates :elective_deferral_limit, :catch_up_limit, :enhanced_catch_up_limit,
    :roth_catch_up_wage_threshold, numericality: { greater_than_or_equal_to: 0 }
  validates :source_name, :source_url, presence: true

  def self.for_pay_date(pay_date)
    find_by(tax_year: pay_date.to_date.year)
  end
end
