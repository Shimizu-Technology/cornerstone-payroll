# frozen_string_literal: true

# Stores tax configuration for a specific tax year.
# Each year has one config with SS wage base, rates, and filing status configs.
class AnnualTaxConfig < ApplicationRecord
  HISTORICAL_SS_WAGE_BASES = {
    2024 => 168_600,
    2025 => 176_100,
    2026 => 184_500
  }.freeze

  has_many :filing_status_configs, dependent: :destroy
  has_many :tax_brackets, through: :filing_status_configs
  has_many :audit_logs, class_name: "TaxConfigAuditLog", dependent: :destroy

  validates :tax_year, presence: true, uniqueness: true
  validates :ss_wage_base, presence: true, numericality: { greater_than: 0 }
  validates :ss_rate, presence: true, numericality: { greater_than_or_equal_to: 0, less_than: 1 }
  validates :medicare_rate, presence: true, numericality: { greater_than_or_equal_to: 0, less_than: 1 }
  validates :additional_medicare_rate, presence: true, numericality: { greater_than_or_equal_to: 0, less_than: 1 }
  validates :additional_medicare_threshold, presence: true, numericality: { greater_than: 0 }

  scope :active, -> { where(is_active: true) }

  # Get config for a specific year (returns single record or nil)
  def self.for_year(year)
    find_by(tax_year: year)
  end

  # Select rules strictly by the requested tax year. `is_active` controls the
  # admin UI/default setup flow; it must never override a pay date's year.
  def self.current(year = Date.current.year)
    for_year(year)
  end

  # The importer must reproduce retained history before a client's tax setup
  # exists. Keep that deliberately narrow fallback beside the annual tax model.
  def self.historical_ss_wage_base(year)
    for_year(year)&.ss_wage_base&.to_d || HISTORICAL_SS_WAGE_BASES[year.to_i]&.to_d
  end

  # Create a new year's config by copying from a previous year
  def self.create_from_previous(new_year, source_year: new_year - 1)
    source = find_by!(tax_year: source_year)

    transaction do
      new_config = create!(
        tax_year: new_year,
        ss_wage_base: source.ss_wage_base,
        ss_rate: source.ss_rate,
        medicare_rate: source.medicare_rate,
        additional_medicare_rate: source.additional_medicare_rate,
        additional_medicare_threshold: source.additional_medicare_threshold,
        is_active: false
      )

      source.filing_status_configs.each do |fsc|
        new_fsc = new_config.filing_status_configs.create!(
          filing_status: fsc.filing_status,
          standard_deduction: fsc.standard_deduction
        )

        fsc.tax_brackets.each do |bracket|
          new_fsc.tax_brackets.create!(
            bracket_order: bracket.bracket_order,
            min_income: bracket.min_income,
            max_income: bracket.max_income,
            rate: bracket.rate
          )
        end
      end

      new_config
    end
  end

  # Activate this config (and deactivate others)
  def activate!
    transaction do
      AnnualTaxConfig.where(is_active: true).update_all(is_active: false)
      update!(is_active: true)
    end
  end

  # Get filing status config
  def config_for(filing_status)
    filing_status_configs.find_by(filing_status: FilingStatusConfig.normalize(filing_status))
  end
end
