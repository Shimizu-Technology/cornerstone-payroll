# frozen_string_literal: true

# Stores tax configuration for a specific tax year.
# Each year has one config with SS wage base, rates, and filing status configs.
class AnnualTaxConfig < ApplicationRecord
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

  # Get the active config, or fall back to the specified year
  # Always returns a single record or nil (never a Relation)
  def self.current(year = Date.current.year)
    active.first || for_year(year)
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
    filing_status_configs.find_by(filing_status: filing_status)
  end
end
