# frozen_string_literal: true

require "rails_helper"

RSpec.describe HistoricalRetirementProjection do
  include HistoricalYtdBridgeFixtureHelper
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let!(:balance) do
    apply_historical_ytd_balance(company: company, employee: employee, through_pay_date: Date.new(2026, 8, 31),
      gross_pay: 40_000, federal_income_tax: 1234, fit_taxable_wages: 39_000,
      retirement: canonical, roth_retirement: 0,
      source_breakdown: { "pretax_deduction_breakdown" => { "401(k) After Tax" => "24000.00" },
        "employer_contribution_breakdown" => { "401(k) After Tax" => "1000.00" } })
  end
  let(:canonical) { 0 }
  let(:projection) { described_class.new(employee: employee, tax_year: 2026) }
  let(:review) do
    source = projection.source
    { "balance_digest" => source[:balance_digest], "classifications" => source[:classifications].map do |row|
      row.stringify_keys.merge("reporting_group" => "401k_after_tax")
    end }
  end

  def save_review(values = review, **overrides)
    employee.employee_retirement_year_inputs.create!({ company: company, tax_year: 2026,
      source_reference: "Signed prior Roth election and retained source", reason: "Verify classification",
      historical_retirement_review: values }.merge(overrides))
  end

  it "requires explicit complete review while profiles remain readable" do
    expect(projection.totals).to include(retirement: 0, roth_retirement: 0)
    expect { projection.totals(strict: true) }.to raise_error(ArgumentError, /Retirement year evidence/)
    expect(employee.merge_historical_ytd({ roth_retirement: 0, gross_pay: 0 }, 2026)).to include(roth_retirement: 0, gross_pay: 40_000)
    expect { save_review(review.merge("classifications" => [])) }.to raise_error(ActiveRecord::RecordInvalid, /every retained candidate/)
  end

  it "recovers Roth once, counts employer additions, and never mutates source/wages/taxes" do
    raw = balance.attributes
    save_review
    2.times do
      fresh = described_class.new(employee: employee, tax_year: 2026)
      expect(fresh.totals(strict: true)).to include(retirement: 0, roth_retirement: 24_000, non_roth_after_tax: 0)
      expect(fresh.employer_additions).to eq(1000)
      expect(employee.merge_historical_ytd({ retirement: 0, roth_retirement: 500 }, 2026)).to include(retirement: 0, roth_retirement: 24_500)
    end
    expect(balance.reload.attributes).to eq(raw)
    expect { EmployeeRetirementYearInput.last.update!(reason: "rewrite") }.to raise_error(ActiveRecord::RecordNotSaved)
  end

  it "counts reviewed non-Roth separately from elective deferrals" do
    review["classifications"][0]["reporting_group"] = "401k_non_roth_after_tax"
    save_review
    expect(described_class.new(employee: employee, tax_year: 2026).totals(strict: true)).to include(roth_retirement: 0, non_roth_after_tax: 24_000)
  end

  it "rejects source digest, amount, label, bucket, unsupported group and year mismatches" do
    invalid = [ review.merge("balance_digest" => "wrong"), review.merge("classifications" => review["classifications"] * 2) ]
    { "amount" => "24001.0", "source_label" => "401k", "source_bucket" => "after_tax_deduction_breakdown", "reporting_group" => "retirement_other" }.each do |key, value|
      changed = review.deep_dup
      changed["classifications"][0][key] = value
      invalid << changed
    end
    invalid.each { |values| expect { save_review(values) }.to raise_error(ActiveRecord::RecordInvalid) }
    expect { save_review(review, tax_year: 2025) }.to raise_error(ActiveRecord::RecordInvalid)
    other = create(:employee)
    expect { described_class.new(employee: other, tax_year: 2026, balance: balance, review: review).validate_review! }.to raise_error(ArgumentError)
  end

  it "blocks calculation when the retained source changes after review" do
    save_review
    balance.update_columns(source_breakdown: balance.source_breakdown.deep_merge("employer_contribution_breakdown" => { "401(k) After Tax" => "1001.00" }))
    expect { described_class.new(employee: employee, tax_year: 2026).totals(strict: true) }.to raise_error(ArgumentError, /digest has changed/)
  end

  it "caps current Roth against the reviewed YTD and retains historical replay evidence" do
    save_review
    AnnualRetirementLimit.find_or_create_by!(tax_year: 2026) do |limit|
      limit.elective_deferral_limit = 24_500
      limit.annual_additions_limit = 72_000
      limit.compensation_limit = 360_000
      limit.catch_up_limit = 8_000
      limit.enhanced_catch_up_limit = 11_250
      limit.roth_catch_up_wage_threshold = 150_000
      limit.source_name = "Verified synthetic limit"
      limit.source_url = "https://www.irs.gov/"
    end
    election = employee.employee_retirement_elections.create!(company: company, effective_on: Date.new(2026, 1, 1),
      plan_name: "Verified 401k", plan_source_reference: "Signed plan", roth_available: true,
      eligible: true, participating: true, roth_contribution_type: "fixed", roth_amount: 1000,
      traditional_contribution_type: "fixed", traditional_amount: 0, source: "staff", reason: "Signed election")
    period = create(:pay_period, company: company, start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 9, 15), pay_date: Date.new(2026, 9, 20))
    item = create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 2000)
    ytd = employee.merge_historical_ytd({ gross_pay: 0, retirement: 0, roth_retirement: 0 }, 2026)
    result = PayrollRetirementCalculation.new(employee: employee, payroll_item: item, ytd_before: ytd, employee_deductions: []).apply!
    expect(item.roth_retirement_payment).to eq(500)
    expect(result.snapshot.dig("annual_additions", "prior_additions").to_d).to eq(25_000)
    expect(result.snapshot["historical_filing_review_required"]).to be(true)
    expect(result.snapshot.dig("employer_match", "prior_ytd").to_d).to eq(1000)
    expect(PayrollStatementYtdBreakdown.new(item).deductions.find { |row| row.semantic == :"401k_after_tax" }.ytd).to eq(24_500)
    raw = balance.attributes
    year_input = employee.retirement_year_input_for(2026)
    employee.employee_retirement_year_inputs.create!(company: company, tax_year: 2026,
      source_reference: "Later unrelated evidence", reason: "Review pending")
    replay = PayrollRetirementCalculation.new(employee: employee, payroll_item: item, ytd_before: {}, employee_deductions: [],
      historical_election: election.snapshot_attributes, historical_limit: result.snapshot["annual_limit"],
      historical_evidence: result.snapshot, historical_mode: true).apply!
    expect(item.roth_retirement_payment).to eq(500)
    expect(replay.snapshot["historical_filing_review_required"]).to be(true)
    expect(replay.snapshot["year_input"]["historical_retirement_review"]).to eq(year_input.historical_retirement_review)
    expect(balance.reload.attributes).to eq(raw)
  end

  it "preserves digest across exact archive copies and rejects promotion without a matching bridge" do
    save_review
    target_company = create(:company, organization: company.organization)
    target = create(:employee, company: target_company)
    actor = create(:user, company: target_company, organization: company.organization)
    EmployeeRetirementYearInputCopier.call(source: employee, target: target, actor: actor, mode: :history)
    expect { described_class.new(employee: target, tax_year: 2026).totals(strict: true) }.to raise_error(ArgumentError)
    copied = apply_historical_ytd_balance(company: target_company, employee: target, through_pay_date: balance.through_pay_date,
      **balance.attributes.symbolize_keys.except(:id, :company_id, :employee_id, :historical_ytd_bridge_id, :created_at, :updated_at,
        :tax_year, :through_pay_date, :through_period_end))
    fresh = described_class.new(employee: target, tax_year: 2026)
    expect(fresh.balance_digest).to eq(projection.balance_digest)
    expect(fresh.totals(strict: true)[:roth_retirement]).to eq(24_000)
    copied.update_columns(gross_pay: 40_001)
    expect { EmployeeRetirementYearInputCopier.call(source: employee, target: target, actor: actor, mode: :latest_per_year) }.to raise_error(ArgumentError, /digest has changed/)
  end

  context "with a candidate already reflected in the canonical bucket" do
    it "does not double count" do
      balance.update_columns(roth_retirement: 24_000)
      save_review
      expect(described_class.new(employee: employee, tax_year: 2026).totals(strict: true)[:roth_retirement]).to eq(24_000)
    end
  end

  context "with an unexplained canonical total" do
    let(:canonical) { 10 }

    it "refuses mismatches instead of summing or reclassifying canonical balances" do
      expect { save_review }.to raise_error(ActiveRecord::RecordInvalid, /does not reconcile/)
    end
  end
end
