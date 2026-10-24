# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Tax-year verification" do
  include ActiveSupport::Testing::TimeHelpers
  def calculator(year, **options)
    GuamTaxCalculatorV2.new(tax_year: year, filing_status: "single", pay_frequency: "biweekly", **options)
  end

  def complete_config(year)
    config = create(:annual_tax_config, tax_year: year)
    FilingStatusConfig::FILING_STATUSES.each do |status|
      filing = create(:filing_status_config, annual_tax_config: config, filing_status: status)
      create(:tax_bracket, filing_status_config: filing, bracket_order: 1, max_income: nil)
    end
    config.reload
  end

  it "copies 2026 into a draft that cannot calculate even when active" do
    complete_config(2026)
    copy = AnnualTaxConfig.create_from_previous(2027, source_year: 2026)
    copy.activate!

    expect(copy.reload.verification_status).to eq("draft")
    expect(copy.verified_by).to be_nil
    expect(AnnualTaxConfig.current(2027)).to be_nil
    expect { calculator(2027) }.to raise_error(ArgumentError, /2027 tax tables have not been verified/)
  end

  it "fails closed for a missing year" do
    expect { calculator(2029) }.to raise_error(ArgumentError, /2029 tax tables have not been verified/)
  end

  it "calculates verified 2027 with the 192300 wage base and records verification evidence" do
    config = complete_config(2027)
    config.update!(ss_wage_base: 192_300)
    admin = create(:user, role: "admin")
    config.verify!(actor: admin, source_note: "Synthetic fixture: SSA https://www.ssa.gov/oact/COLA/cbb.html")

    expect(config.verified_by).to eq(admin.id.to_s)
    expect(config.verified_at).to be_present
    expect(calculator(2027).calculate(gross_pay: 1000, ytd_gross: 192_000)[:social_security]).to eq(18.60)
  end

  it "does not permit verification without source evidence or complete withholding tables" do
    config = create(:annual_tax_config, tax_year: 2027)
    admin = create(:user, role: "admin")
    expect { config.verify!(actor: admin, source_note: "") }.to raise_error(ArgumentError, /source/i)
    expect { config.verify!(actor: admin, source_note: "Synthetic review") }.to raise_error(ArgumentError, /withholding/i)
  end

  it "preserves inactive historical snapshot replay after current rules become draft" do
    config = complete_config(2026)
    config.verify!(actor: create(:user, role: "admin"), source_note: "Synthetic historical rules")
    original = calculator(2026)
    snapshot = original.rule_snapshot
    expected = original.calculate(gross_pay: 2000)
    config.update!(ss_wage_base: 1)

    expect(config.reload).not_to be_verified
    expect(calculator(2026, rule_snapshot: snapshot).calculate(gross_pay: 2000)).to eq(expected)
  end

  it "invalidates verification when a rate or bracket changes" do
    config = complete_config(2027)
    config.verify!(actor: create(:user, role: "admin"), source_note: "Synthetic review")
    config.tax_brackets.first.update!(rate: 0.22)
    expect(config.reload).not_to be_verified
  end

  it "reports the upcoming year starting 60 days before January" do
    complete_config(2026)
    travel_to(Time.zone.local(2026, 11, 1)) do
      expect(TaxYearReadiness.new.as_json[:warnings].map { |warning| warning[:tax_year] }).not_to include(2027)
    end
    travel_to(Time.zone.local(2026, 11, 2)) do
      expect(TaxYearReadiness.new.as_json[:warnings].map { |warning| warning[:tax_year] }).to include(2027)
    end
  end

  it "seeds only sourced 2027 FICA values and keeps withholding and retirement absent" do
    load Rails.root.join("db/seeds/tax_config_2027_draft.rb")
    config = AnnualTaxConfig.for_year(2027)
    expect(config.ss_wage_base).to eq(192_300)
    expect(config).not_to be_verified
    expect(config.filing_status_configs).to be_empty
    expect(AnnualRetirementLimit.find_by(tax_year: 2027)).to be_nil
    expect(config.source_references).to include("https://www.ssa.gov/oact/COLA/cbb.html")
    config.update!(ss_wage_base: 192_301)
    load Rails.root.join("db/seeds/tax_config_2027_draft.rb")
    expect(config.reload.ss_wage_base).to eq(192_301)
  end

  it "cannot use a future legacy tax table to bypass a missing annual year" do
    create(:tax_table, tax_year: 2027)
    expect { AnnualTaxConfig.require_verified!(2027) }.to raise_error(ArgumentError, /2027 tax tables have not been verified/)
  end

  it "surfaces upcoming verification failures in production readiness" do
    travel_to(Time.zone.local(2026, 11, 2)) do
      report = ProductionReadiness.new.run(live: false)
      check = report.failures.find { |failure| failure.name == "2027 payroll tax tables are verified" }
      expect(check.detail).to include("2027 tax tables have not been verified")
    end
  end

  it "blocks approval and commit with a draft without changing the saved state" do
    complete_config(2026)
    AnnualTaxConfig.create_from_previous(2027, source_year: 2026)
    period = create(:pay_period, start_date: Date.new(2027, 1, 1), end_date: Date.new(2027, 1, 14), pay_date: Date.new(2027, 1, 15))
    %w[approved committed].each do |status|
      expect { period.update!(status: status) }.to raise_error(ActiveRecord::RecordInvalid, /2027 tax tables have not been verified/)
      expect(period.reload.status).to eq("draft")
    end
  end
end
