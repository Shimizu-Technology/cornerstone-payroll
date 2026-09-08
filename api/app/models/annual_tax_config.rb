# frozen_string_literal: true

# Stores tax configuration for a specific tax year.
# Each year has one config with SS wage base, rates, and filing status configs.
class AnnualTaxConfig < ApplicationRecord
  OFFICIAL_2026_PAYROLL_TAX_SOURCE = {
    "name" => "IRS Publication 15 (2026), Employer's Tax Guide",
    "url" => "https://www.irs.gov/publications/p15",
    "effective_year" => 2026
  }.freeze
  OFFICIAL_2026_WITHHOLDING_SOURCE = {
    "name" => "IRS Publication 15-T (2026), Percentage Method Tables for Automated Payroll Systems",
    "url" => "https://www.irs.gov/publications/p15t",
    "effective_year" => 2026
  }.freeze
  OFFICIAL_2026_PAYROLL_TAXES = {
    ss_wage_base: 184_500.to_d,
    ss_rate: 0.062.to_d,
    medicare_rate: 0.0145.to_d,
    additional_medicare_rate: 0.009.to_d,
    additional_medicare_threshold: 200_000.to_d
  }.freeze
  OFFICIAL_2026_WITHHOLDING = {
    "single" => {
      adjustment: 8_600,
      standard: [
        [ 0, 7_500, 0.00 ], [ 7_500, 19_900, 0.10 ], [ 19_900, 57_900, 0.12 ],
        [ 57_900, 113_200, 0.22 ], [ 113_200, 209_275, 0.24 ], [ 209_275, 263_725, 0.32 ],
        [ 263_725, 648_100, 0.35 ], [ 648_100, nil, 0.37 ]
      ],
      step2: [
        [ 0, 8_050, 0.00 ], [ 8_050, 14_250, 0.10 ], [ 14_250, 33_250, 0.12 ],
        [ 33_250, 60_900, 0.22 ], [ 60_900, 108_938, 0.24 ], [ 108_938, 136_163, 0.32 ],
        [ 136_163, 328_350, 0.35 ], [ 328_350, nil, 0.37 ]
      ]
    },
    "married" => {
      adjustment: 12_900,
      standard: [
        [ 0, 19_300, 0.00 ], [ 19_300, 44_100, 0.10 ], [ 44_100, 120_100, 0.12 ],
        [ 120_100, 230_700, 0.22 ], [ 230_700, 422_850, 0.24 ], [ 422_850, 531_750, 0.32 ],
        [ 531_750, 788_000, 0.35 ], [ 788_000, nil, 0.37 ]
      ],
      step2: [
        [ 0, 16_100, 0.00 ], [ 16_100, 28_500, 0.10 ], [ 28_500, 66_500, 0.12 ],
        [ 66_500, 121_800, 0.22 ], [ 121_800, 217_875, 0.24 ], [ 217_875, 272_325, 0.32 ],
        [ 272_325, 400_450, 0.35 ], [ 400_450, nil, 0.37 ]
      ]
    },
    "head_of_household" => {
      adjustment: 8_600,
      standard: [
        [ 0, 15_550, 0.00 ], [ 15_550, 33_250, 0.10 ], [ 33_250, 83_000, 0.12 ],
        [ 83_000, 121_250, 0.22 ], [ 121_250, 217_300, 0.24 ], [ 217_300, 271_750, 0.32 ],
        [ 271_750, 656_150, 0.35 ], [ 656_150, nil, 0.37 ]
      ],
      step2: [
        [ 0, 12_075, 0.00 ], [ 12_075, 20_925, 0.10 ], [ 20_925, 45_800, 0.12 ],
        [ 45_800, 64_925, 0.22 ], [ 64_925, 112_950, 0.24 ], [ 112_950, 140_175, 0.32 ],
        [ 140_175, 332_375, 0.35 ], [ 332_375, nil, 0.37 ]
      ]
    }
  }.freeze
  HISTORICAL_SS_WAGE_BASES = {
    2018 => 128_400,
    2019 => 132_900,
    2020 => 137_700,
    2021 => 142_800,
    2022 => 147_000,
    2023 => 160_200,
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

  def self.official_2026_payroll_tax_config?(config = for_year(2026))
    config.present? && OFFICIAL_2026_PAYROLL_TAXES.all? do |attribute, expected|
      config.public_send(attribute).to_d == expected
    end
  end

  def self.official_2026_configuration?(config = for_year(2026))
    official_2026_payroll_tax_config?(config) &&
      OFFICIAL_2026_WITHHOLDING.keys.all? do |filing_status|
        config.official_2026_withholding_config?(config.config_for(filing_status))
      end
  end

  def official_2026_withholding_config?(filing_config)
    return false unless tax_year == 2026 && filing_config.present?

    expected = OFFICIAL_2026_WITHHOLDING[filing_config.filing_status]
    return false unless expected
    return false unless filing_config.standard_deduction.to_d == expected.fetch(:adjustment).to_d

    actual_brackets = filing_config.tax_brackets.order(:bracket_order).map do |bracket|
      [ bracket.min_income.to_d, bracket.max_income&.to_d, bracket.rate.to_d ]
    end
    expected_brackets = expected.fetch(:standard).map do |minimum, maximum, rate|
      [ minimum.to_d, maximum&.to_d, rate.to_d ]
    end
    actual_brackets == expected_brackets
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
