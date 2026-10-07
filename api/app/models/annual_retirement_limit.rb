# frozen_string_literal: true

class AnnualRetirementLimit < ApplicationRecord
  validates :tax_year, inclusion: { in: 2000..2200 }, uniqueness: true
  validates :elective_deferral_limit, :catch_up_limit, :enhanced_catch_up_limit,
    :roth_catch_up_wage_threshold, numericality: { greater_than_or_equal_to: 0 }
  validates :source_name, :source_url, presence: true
  validates :annual_additions_limit, :compensation_limit,
    numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :source_is_irs

  def complete?
    annual_additions_limit.present? && compensation_limit.present?
  end

  def self.for_pay_date(pay_date)
    find_by(tax_year: pay_date.to_date.year)
  end

  private

  def source_is_irs
    uri = URI.parse(source_url.to_s)
    return if uri.scheme == "https" && [ "irs.gov", "www.irs.gov" ].include?(uri.host)

    errors.add(:source_url, "must link to an official HTTPS IRS source")
  rescue URI::InvalidURIError
    errors.add(:source_url, "must be a valid IRS URL")
  end
end
