# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260909090000_harden_2026_payroll_tax_configuration")

RSpec.describe GuamTaxCalculatorV2, "2026 IRS Publication 15-T" do
  SOURCE_URL = "https://www.irs.gov/publications/p15t"

  before do
    allow($stdout).to receive(:puts)
    load Rails.root.join("db/seeds/tax_configs.rb")
  end

  # Expected amounts are worked from Worksheet 1A and the annual Percentage
  # Method tables in the official 2026 publication, without using app helpers.
  {
    "single" => { "weekly" => 270.19, "biweekly" => 156.15, "semimonthly" => 149.17, "monthly" => 65.83 },
    "married" => { "weekly" => 156.15, "biweekly" => 76.15, "semimonthly" => 65.83, "monthly" => 0.00 },
    "head_of_household" => { "weekly" => 201.31, "biweekly" => 114.92, "semimonthly" => 104.50, "monthly" => 0.00 }
  }.each do |filing_status, vectors|
    vectors.each do |pay_frequency, expected|
      it "matches the official #{filing_status} #{pay_frequency} standard vector" do
        calculator = described_class.new(
          tax_year: 2026,
          filing_status: filing_status,
          pay_frequency: pay_frequency
        )

        expect(calculator.calculate(gross_pay: 2_000).fetch(:withholding)).to eq(expected.to_d)
        expect(calculator.rule_snapshot.fetch("withholding_source")).to include("url" => SOURCE_URL)
        expect(calculator.rule_snapshot.fetch("payroll_tax_source")).to include(
          "url" => "https://www.irs.gov/publications/p15"
        )
      end
    end
  end

  it "uses the official Step 2 checkbox schedules for every filing status" do
    expected = { "single" => 270.19, "married" => 156.15, "head_of_household" => 201.31 }

    expected.each do |filing_status, amount|
      calculator = described_class.new(
        tax_year: 2026,
        filing_status: filing_status,
        pay_frequency: "biweekly",
        w4_step2_multiple_jobs: true
      )

      expect(calculator.calculate(gross_pay: 2_000).fetch(:withholding)).to eq(amount.to_d)
    end
  end

  it "applies Form W-4 Steps 3, 4(a), and 4(b) as annual amounts" do
    baseline = described_class.new(tax_year: 2026, filing_status: "single", pay_frequency: "biweekly")
    with_step3 = described_class.new(tax_year: 2026, filing_status: "single", pay_frequency: "biweekly")
    with_step4a = described_class.new(
      tax_year: 2026, filing_status: "single", pay_frequency: "biweekly", w4_step4a_other_income: 5_200
    )
    with_step4b = described_class.new(
      tax_year: 2026, filing_status: "single", pay_frequency: "biweekly", w4_step4b_deductions: 5_200
    )

    expect(baseline.calculate(gross_pay: 2_000).fetch(:withholding)).to eq(156.15)
    expect(with_step3.calculate(gross_pay: 2_000, w4_dependent_credit: 520).fetch(:withholding)).to eq(136.15)
    expect(with_step4a.calculate(gross_pay: 2_000).fetch(:withholding)).to eq(180.15)
    expect(with_step4b.calculate(gross_pay: 2_000).fetch(:withholding)).to eq(132.15)
  end

  it "replays the official Step 2 schedule from the committed rule snapshot" do
    calculator = described_class.new(
      tax_year: 2026,
      filing_status: "single",
      pay_frequency: "biweekly",
      w4_step2_multiple_jobs: true
    )
    snapshot = calculator.rule_snapshot
    AnnualTaxConfig.for_year(2026).config_for("single").tax_brackets.update_all(rate: 0.50)

    replay = described_class.new(
      tax_year: 2026,
      filing_status: "single",
      pay_frequency: "biweekly",
      w4_step2_multiple_jobs: true,
      rule_snapshot: snapshot
    )

    expect(replay.calculate(gross_pay: 2_000).fetch(:withholding)).to eq(270.19)
    expect(replay.rule_snapshot).to eq(snapshot)
  end

  it "layers Form W-4 Step 4(c) as a per-pay-period amount in payroll" do
    company = create(:company)
    department = create(:department, company: company)
    employee = create(
      :employee,
      company: company,
      department: department,
      filing_status: "single",
      pay_frequency: "biweekly",
      pay_rate: 20,
      additional_withholding: 25
    )
    pay_period = create(:pay_period, company: company, pay_date: Date.new(2026, 1, 16))
    payroll_item = create(
      :payroll_item,
      employee: employee,
      pay_period: pay_period,
      pay_rate: 20,
      hours_worked: 100
    )

    PayrollCalculator.for(employee, payroll_item).calculate

    expect(payroll_item.withholding_tax).to eq(156.15)
    expect(payroll_item.additional_withholding).to eq(25.00)
    expect(payroll_item.tax_rule_snapshot.dig("w4", "step4c_extra_withholding")).to eq(25.0)
  end

  it "repairs an already-seeded 2026 configuration idempotently" do
    config = AnnualTaxConfig.find_by!(tax_year: 2026)
    config.update!(ss_wage_base: 1, additional_medicare_threshold: 250_000)
    config.config_for("single").tax_brackets.first.update!(rate: 0.50)

    load Rails.root.join("db/seeds/tax_configs.rb")

    expect(AnnualTaxConfig.official_2026_payroll_tax_config?(config.reload)).to be(true)
    expect(config).to be_official_2026_withholding_config(config.config_for("single"))
  end

  it "fails the exact configuration assertion when a withholding bracket drifts" do
    expect(AnnualTaxConfig.official_2026_configuration?).to be(true)

    AnnualTaxConfig.for_year(2026).config_for("married").tax_brackets.second.update!(rate: 0.11)

    expect(AnnualTaxConfig.official_2026_configuration?).to be(false)
  end

  it "migrates existing production rows and the legacy married Medicare threshold idempotently" do
    config = AnnualTaxConfig.for_year(2026)
    config.update!(ss_wage_base: 1)
    config.config_for("single").update!(standard_deduction: 1)
    legacy = TaxTable.find_or_initialize_by(tax_year: 2026, filing_status: "married", pay_frequency: "biweekly")
    legacy.assign_attributes(
      bracket_data: [ { min_income: 0, max_income: nil, base_tax: 0, rate: 0, threshold: 0 } ],
      ss_wage_base: 184_500, ss_rate: 0.062, medicare_rate: 0.0145,
      additional_medicare_rate: 0.009, additional_medicare_threshold: 250_000
    )
    legacy.save!

    ActiveRecord::Migration.suppress_messages do
      2.times { Harden2026PayrollTaxConfiguration.new.migrate(:up) }
    end

    expect(AnnualTaxConfig.official_2026_configuration?(config.reload)).to be(true)
    expect(legacy.reload.additional_medicare_threshold).to eq(200_000.to_d)
  end
end
