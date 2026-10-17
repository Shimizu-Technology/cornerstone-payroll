# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollRetirementCalculation do
  include HistoricalYtdBridgeFixtureHelper

  let(:company) { create(:company) }
  let(:employee) do
    create(:employee, company: company, department: create(:department, company: company),
      date_of_birth: Date.new(1980, 6, 1), retirement_rate: 0, roth_retirement_rate: 0)
  end
  let(:pay_period) do
    create(:pay_period, company: company, start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 9, 15), pay_date: Date.new(2026, 9, 20))
  end
  let(:payroll_item) do
    create(:payroll_item, employee: employee, pay_period: pay_period, company: company,
      employment_type: "hourly", pay_rate: 25, hours_worked: 80, gross_pay: 2_000)
  end
  let(:ytd_before) { { gross_pay: 40_000, retirement: 0, roth_retirement: 0 } }

  before do
    AnnualRetirementLimit.find_or_create_by!(tax_year: 2026) do |limit|
      limit.annual_additions_limit = 72_000
      limit.compensation_limit = 360_000
      limit.elective_deferral_limit = 24_500
      limit.catch_up_limit = 8_000
      limit.enhanced_catch_up_limit = 11_250
      limit.roth_catch_up_wage_threshold = 150_000
      limit.source_name = "IRS 2026 limits"
      limit.source_url = "https://www.irs.gov/retirement-plans/plan-participant-employee/retirement-topics-catch-up-contributions"
    end
  end

  def create_election(overrides = {})
    employee.employee_retirement_elections.create!({
      company: company,
      effective_on: Date.new(2026, 1, 1),
      plan_name: "MoSa 401(k)",
      plan_source_reference: "Synthetic signed plan document",
      roth_available: true,
      employer_roth_available: true,
      eligible: true,
      participating: true,
      traditional_contribution_type: "fixed",
      traditional_rate: 0,
      traditional_amount: 500,
      roth_contribution_type: "fixed",
      roth_rate: 0,
      roth_amount: 250,
      eligible_compensation: "gross_wages",
      catch_up_enabled: false,
      limit_priority: "proportional",
      employer_match_mode: "none",
      employer_match_rate: 0,
      employer_match_ytd_before_system: 0,
      employer_match_destination: "traditional",
      true_up_policy: "none",
      source: "staff",
      reason: "Signed election received"
    }.merge(overrides))
  end

  def year_evidence(wages: 0, **overrides)
    employee.employee_retirement_year_inputs.create!({
      company: company, tax_year: 2026,
      prior_year_wage_status: wages.zero? ? "no_prior_employer_wages" : "verified",
      prior_year_fica_wages: wages, prior_year_wage_source: "Synthetic W-2 Box 3 evidence",
      source_reference: "Synthetic year reconciliation", reason: "Verified synthetic test records"
    }.merge(overrides))
  end

  def employer_field(amount: 100, group: "401k_after_tax", percentage: false)
    definition = PayrollFieldDefinition.create!(company: company, name: "Synthetic employer #{group}",
      kind: "employer_contribution", tax_treatment: "employer_contribution", category: "retirement",
      amount_type: percentage ? "percentage" : "fixed", default_percentage: percentage ? 5 : nil,
      default_amount: percentage ? nil : amount, reporting_group: group)
    payroll_item.payroll_item_field_entries.build(payroll_field_definition: definition, label: definition.name,
      kind: definition.kind, tax_treatment: definition.tax_treatment, category: definition.category,
      reporting_group: group, amount: amount, active: true, source: "employee_default")
  end

  def employer_deduction(group: "401k_after_tax", percentage: false)
    type = company.deduction_types.create!(name: "Synthetic recurring employer #{group}",
      category: "employer_contribution", sub_category: "retirement", reporting_group: group)
    employee.employee_deductions.create!(deduction_type: type, amount: percentage ? 5 : 100,
      is_percentage: percentage, active: true)
  end

  def calculate(ytd: ytd_before, deductions: [])
    described_class.new(
      employee: employee,
      payroll_item: payroll_item,
      ytd_before: ytd,
      employee_deductions: deductions,
      recurring_items_enabled: true
    ).apply!
  end

  describe "final available-pay explanations" do
    [
      [ "zero string and integer amounts", { "traditional" => "0.0", "roth" => "0.0", "non_roth_after_tax" => "0.0" }, [ 0, 0, 0 ], false ],
      [ "missing zero buckets", {}, [ 0, 0, 0 ], false ],
      [ "unchanged nonzero amounts with mixed representations", { "traditional" => "100.00", "roth" => 50, "non_roth_after_tax" => BigDecimal("25.0") }, [ 100, 50, 25 ], false ],
      [ "an increase in contributions", { "traditional" => "100", "roth" => "0", "non_roth_after_tax" => "0" }, [ 125, 0, 0 ], false ],
      [ "equal-total redistribution between contribution buckets", { "traditional" => "150", "roth" => "50" }, [ 100, 80, 20 ], false ],
      [ "a traditional contribution reduction", { "traditional" => "125", "roth" => "0" }, [ 100, 0, 0 ], true ],
      [ "a Roth contribution reduction", { "traditional" => "0", "roth" => "125" }, [ 0, 100, 0 ], true ],
      [ "a non-Roth after-tax contribution reduction", { "traditional" => "0", "roth" => "0", "non_roth_after_tax" => "125" }, [ 0, 0, 100 ], true ]
    ].each do |label, previous, final, reduced|
      it "#{reduced ? 'explains' : 'does not claim a reduction for'} #{label}" do
        create_election(traditional_amount: final[0], roth_amount: final[1])
        if final[2].positive?
          definition = create(:payroll_field_definition, company: company, name: "Non-Roth after-tax contribution",
            kind: "deduction", tax_treatment: "post_tax_deduction", category: "retirement",
            amount_type: "fixed", default_amount: final[2], reporting_group: "401k_non_roth_after_tax")
          payroll_item.payroll_item_field_entries.build(payroll_field_definition: definition, label: definition.name,
            kind: definition.kind, tax_treatment: definition.tax_treatment, category: definition.category,
            reporting_group: definition.reporting_group, amount: final[2], active: true, employee_paid: true, source: "manual")
        end
        engine = described_class.new(employee: employee, payroll_item: payroll_item,
          ytd_before: ytd_before, employee_deductions: [])
        engine.apply!
        payroll_item.retirement_rule_snapshot["applied"] = previous
        original_explanations = payroll_item.retirement_rule_snapshot.fetch("explanations").dup

        engine.reconcile_final!

        snapshot = payroll_item.retirement_rule_snapshot
        expect(snapshot.fetch("applied").values.sum(&:to_d)).to eq(final.sum.to_d)
        expect(snapshot.fetch("explanations").any? { |reason| reason.include?("enough available pay") }).to eq(reduced)
        expect(original_explanations - snapshot.fetch("explanations")).to be_empty
      end
    end
  end

  it "applies fixed traditional and Roth elections and preserves the rule evidence" do
    election = create_election

    calculate

    expect(payroll_item.retirement_payment).to eq(500)
    expect(payroll_item.roth_retirement_payment).to eq(250)
    expect(payroll_item.retirement_rule_snapshot).to include(
      "election" => include("election_id" => election.id, "plan_name" => "MoSa 401(k)"),
      "annual_limit" => include("elective_deferral_limit" => "24500.0"),
      "applied" => { "traditional" => "500.0", "roth" => "250.0", "non_roth_after_tax" => "0.0" }
    )
  end

  it "caps combined traditional and Roth deferrals against YTD exactly once" do
    create_election

    calculate(ytd: ytd_before.merge(retirement: 20_000, roth_retirement: 4_400))

    expect(payroll_item.retirement_payment + payroll_item.roth_retirement_payment).to eq(100)
    expect(payroll_item.retirement_rule_snapshot["ytd_employee_deferral_before"]).to eq("24400.0")
    expect(payroll_item.retirement_rule_snapshot["explanations"]).to include(/annual plan limit/)
  end

  it "includes flexible payroll fields in the same annual cap" do
    create_election(traditional_amount: 0, roth_amount: 0)
    definition = PayrollFieldDefinition.create!(
      company: company, name: "Owner 401(k)", kind: "deduction", tax_treatment: "pre_tax_deduction",
      category: "retirement", amount_type: "fixed", default_amount: 200,
      reporting_group: "401k_pre_tax"
    )
    entry = payroll_item.payroll_item_field_entries.build(
      payroll_field_definition: definition, label: definition.name, kind: definition.kind,
      tax_treatment: definition.tax_treatment, category: definition.category,
      reporting_group: definition.reporting_group, amount: 200, active: true,
      employee_paid: true, employer_paid: false, source: "manual"
    )

    calculate(ytd: ytd_before.merge(retirement: 24_450))

    expect(entry.amount).to eq(50)
    expect(entry.metadata["uncapped_amount"]).to eq("200.0")
  end

  it "uses the enhanced catch-up limit for an employee age 60 through 63" do
    employee.update!(date_of_birth: Date.new(1965, 6, 1))
    payroll_item.update!(gross_pay: 12_000)
    create_election(catch_up_enabled: true, traditional_amount: 11_250, roth_amount: 0)

    year_evidence
    calculate(ytd: ytd_before.merge(retirement: 24_500))

    expect(payroll_item.retirement_payment).to eq(11_250)
    expect(payroll_item.retirement_rule_snapshot["employee_age_at_year_end"]).to eq(61)
  end

  it "does not put a high-earner catch-up amount into traditional contributions" do
    employee.update!(date_of_birth: Date.new(1970, 6, 1))
    create_election(catch_up_enabled: true, traditional_amount: 500, roth_amount: 500, limit_priority: "traditional_first")
    year_evidence(wages: 175_000)

    calculate(ytd: ytd_before.merge(retirement: 24_500))

    expect(payroll_item.retirement_payment).to eq(0)
    expect(payroll_item.roth_retirement_payment).to eq(500)
    expect(payroll_item.retirement_rule_snapshot["roth_catch_up_required"]).to be(true)
  end

  it "matches employee deferrals with per-period and annual caps" do
    create_election(
      traditional_amount: 300,
      roth_amount: 0,
      employer_match_mode: "employee_deferral_percentage",
      employer_match_rate: 1,
      employer_match_deferral_cap_rate: 0.10,
      employer_match_period_cap: 175,
      employer_match_annual_cap: 1_000
    )

    calculate

    expect(payroll_item.employer_retirement_match).to eq(175)
    expect(payroll_item.employer_roth_retirement_match).to eq(0)
  end

  it "preserves legacy contributions before the first future election" do
    employee.update!(retirement_rate: 0.1)
    create_election(effective_on: Date.new(2026, 10, 1))

    calculate

    expect(payroll_item.retirement_payment).to eq(200)
    expect(payroll_item.roth_retirement_payment).to eq(0)
    expect(payroll_item.retirement_rule_snapshot.dig("election", "source")).to eq("legacy_employee_profile")
  end

  it "blocks an active dated election when the pay year's annual limits are missing" do
    pay_period.update!(start_date: Date.new(2027, 9, 1), end_date: Date.new(2027, 9, 15), pay_date: Date.new(2027, 9, 20))
    create_election(effective_on: Date.new(2027, 1, 1))

    expect { calculate }.to raise_error(ArgumentError, /Retirement limits are not configured for 2027/)
  end

  it "reconciles a year-to-date match without paying the imported QuickBooks amount twice" do
    create_election(
      traditional_amount: 200,
      roth_amount: 0,
      employer_match_mode: "employee_deferral_percentage",
      employer_match_rate: 1,
      employer_match_ytd_before_system: 900,
      true_up_policy: "year_to_date"
    )

    calculate(ytd: ytd_before.merge(retirement: 1_000))

    expect(payroll_item.employer_retirement_match).to eq(300)
    expect(payroll_item.retirement_rule_snapshot.dig("employer_match", "prior_ytd")).to eq("900.0")
  end
  it "fails closed for legacy contributions without verified annual rules" do
    AnnualRetirementLimit.where(tax_year: 2026).delete_all
    employee.update!(retirement_rate: 0.1)
    expect { calculate }.to raise_error(ArgumentError, /Retirement limits are not configured/)
  end

  it "leaves non-retirement payroll usable without annual retirement rules" do
    AnnualRetirementLimit.where(tax_year: 2026).delete_all
    expect { calculate }.not_to raise_error
  end

  it "blocks attempted catch-up when prior-year wage evidence is unknown" do
    employee.update!(date_of_birth: Date.new(1976, 12, 31))
    create_election(catch_up_enabled: true)
    expect { calculate(ytd: ytd_before.merge(retirement: 24_500)) }.to raise_error(ArgumentError, /verified prior-year employer/)
  end

  it "credits earlier Roth deferrals before restricting Traditional catch-up" do
    employee.update!(date_of_birth: Date.new(1970, 6, 1))
    create_election(catch_up_enabled: true, traditional_amount: 500, roth_amount: 0)
    year_evidence(wages: 150_001)
    calculate(ytd: ytd_before.merge(retirement: 16_500, roth_retirement: 8_000))
    expect(payroll_item.retirement_payment).to eq(500)
  end

  it "uses a strict greater-than prior-year wage threshold" do
    employee.update!(date_of_birth: Date.new(1970, 6, 1))
    create_election(catch_up_enabled: true, traditional_amount: 500, roth_amount: 0)
    year_evidence(wages: 150_000)
    calculate(ytd: ytd_before.merge(retirement: 24_500))
    expect(payroll_item.retirement_payment).to eq(500)
    expect(payroll_item.retirement_rule_snapshot["roth_catch_up_required"]).to be(false)
  end

  it "uses external deferrals for personal limits without using them for employer matching" do
    create_election(traditional_amount: 5_000, roth_amount: 0, employer_match_mode: "employee_deferral_percentage", employer_match_rate: 1)
    year_evidence(external_traditional_deferrals: 10_000)
    calculate(ytd: ytd_before.merge(retirement: 14_000))
    expect(payroll_item.retirement_payment).to eq(500)
    expect(payroll_item.employer_retirement_match).to eq(500)
  end

  it "does not count outside-employer deferrals against a lower local plan limit" do
    employee.update!(date_of_birth: Date.new(1970, 6, 1))
    create_election(traditional_amount: 500, roth_amount: 0, regular_plan_deferral_limit: 10_000, catch_up_enabled: true)
    year_evidence(external_traditional_deferrals: 10_000)
    calculate(ytd: ytd_before.merge(retirement: 5_000))
    expect(payroll_item.retirement_payment).to eq(500)
    expect(payroll_item.retirement_rule_snapshot["annual_additions"]["current_catch_up"]).to eq("0.0")
  end

  it "recognizes catch-up above a lower verified regular plan limit" do
    employee.update!(date_of_birth: Date.new(1970, 6, 1))
    create_election(traditional_amount: 500, roth_amount: 0, regular_plan_deferral_limit: 10_000, catch_up_enabled: true)
    year_evidence
    calculate(ytd: ytd_before.merge(retirement: 10_000))
    expect(payroll_item.retirement_rule_snapshot["annual_additions"]["current_catch_up"]).to eq("500.0")
  end

  it "caps employer match compensation without stopping later employee deferrals" do
    create_election(traditional_amount: 500, roth_amount: 0, employer_match_mode: "compensation_percentage", employer_match_rate: 0.05)
    calculate(ytd: ytd_before.merge(gross_pay: 360_000))
    expect(payroll_item.retirement_payment).to eq(500)
    expect(payroll_item.employer_retirement_match).to eq(0)
  end

  it "counts historical nonelective additions without subtracting them from a matching true-up" do
    apply_historical_ytd_balance(company: company, employee: employee,
      through_pay_date: Date.new(2026, 8, 31), gross_pay: 40_000,
      source_breakdown: { "employer_contribution_breakdown" => { "401(k) Contribution" => "1000.0" } })
    create_election(traditional_amount: 500, roth_amount: 0, employer_match_mode: "compensation_percentage",
      employer_match_rate: 0.03, true_up_policy: "year_to_date")

    calculate

    expect(payroll_item.employer_retirement_match).to eq(1_260)
    expect(payroll_item.retirement_rule_snapshot.dig("employer_match", "prior_ytd")).to eq("0.0")
    expect(payroll_item.retirement_rule_snapshot.dig("annual_additions", "prior_additions")).to eq("1000.0")
  end

  it "does not use historical nonelective additions to consume an annual match cap" do
    apply_historical_ytd_balance(company: company, employee: employee,
      through_pay_date: Date.new(2026, 8, 31), gross_pay: 40_000,
      source_breakdown: { "employer_contribution_breakdown" => { "401(k) Contribution" => "1000.0" } })
    create_election(traditional_amount: 500, roth_amount: 0, employer_match_mode: "compensation_percentage",
      employer_match_rate: 0.03, employer_match_annual_cap: 1_000)

    calculate

    expect(payroll_item.employer_retirement_match).to eq(60)
    expect(payroll_item.retirement_rule_snapshot.dig("annual_additions", "prior_additions")).to eq("1000.0")
  end

  it "raises instead of silently cutting a promised match above the annual additions limit" do
    create_election(traditional_amount: 500, roth_amount: 0, employer_match_mode: "employee_deferral_percentage", employer_match_rate: 1)
    year_evidence(employer_additions_before_system: 71_500, opening_balances_verified: true)
    expect { calculate(ytd: ytd_before.merge(gross_pay: 100_000)) }.to raise_error(ArgumentError, /promised employer contributions cannot be silently reduced/)
  end

  it "classifies additions-limit catch-up below the elective-deferral ceiling" do
    employee.update!(date_of_birth: Date.new(1970, 6, 1))
    create_election(traditional_amount: 500, roth_amount: 0, catch_up_enabled: true)
    year_evidence(employer_additions_before_system: 72_000, opening_balances_verified: true)
    calculate(ytd: ytd_before.merge(gross_pay: 100_000))
    expect(payroll_item.retirement_rule_snapshot["annual_additions"]["current_catch_up"]).to eq("500.0")
  end

  it "replays saved eligibility and wage evidence after current profile changes" do
    employee.update!(date_of_birth: Date.new(1970, 6, 1))
    create_election(traditional_amount: 500, roth_amount: 0, catch_up_enabled: true)
    year_evidence
    calculate(ytd: ytd_before.merge(retirement: 24_500))
    saved = payroll_item.retirement_rule_snapshot.deep_dup
    employee.update!(date_of_birth: Date.new(1990, 1, 1))
    year_evidence(wages: 200_000)
    described_class.new(employee: employee, payroll_item: payroll_item, ytd_before: ytd_before,
      employee_deductions: [], historical_mode: true, historical_evidence: saved.deep_symbolize_keys,
      historical_election: saved["election"], historical_limit: saved["annual_limit"]).apply!
    expect(payroll_item.retirement_payment).to eq(500)
    expect(payroll_item.retirement_rule_snapshot["employee_age_at_year_end"]).to eq(56)
    expect(payroll_item.retirement_rule_snapshot["prior_year_fica_wages"]).to eq("0.0")
  end

  [ [ 49, 0 ], [ 50, 8_000 ], [ 59, 8_000 ], [ 60, 11_250 ], [ 63, 11_250 ], [ 64, 8_000 ] ].each do |age, allowance|
    it "uses the year-end age #{age} catch-up tier, including December birthdays" do
      employee.update!(date_of_birth: Date.new(2026 - age, 12, 31))
      payroll_item.update!(gross_pay: 12_000)
      create_election(catch_up_enabled: true, traditional_amount: 12_000, roth_amount: 0)
      year_evidence
      calculate(ytd: ytd_before.merge(retirement: 24_500))
      expect(payroll_item.retirement_payment).to eq(allowance)
    end
  end

  it "includes non-Roth after-tax employee contributions in additions without consuming elective-deferral capacity" do
    create_election(traditional_amount: 0, roth_amount: 0)
    year_evidence(employer_additions_before_system: 45_000, eligible_compensation_before_system: 100_000, opening_balances_verified: true)
    definition = PayrollFieldDefinition.create!(company: company, name: "Non-Roth 401(k) After Tax", kind: "deduction",
      tax_treatment: "post_tax_deduction", category: "retirement", amount_type: "fixed", default_amount: 2_000,
      reporting_group: "401k_non_roth_after_tax")
    entry = payroll_item.payroll_item_field_entries.build(payroll_field_definition: definition, label: definition.name,
      kind: definition.kind, tax_treatment: definition.tax_treatment, category: definition.category,
      reporting_group: definition.reporting_group, amount: 2_000, active: true, employee_paid: true, employer_paid: false, source: "manual")
    calculate(ytd: ytd_before.merge(retirement: 24_500))
    expect(entry.amount).to eq(2_000)
    expect(PayrollRetirementTotals.for_item(payroll_item)[:roth_retirement]).to eq(0)
    expect(payroll_item.retirement_rule_snapshot.dig("annual_additions", "regular_additions_after")).to eq("71500.0")
  end

  it "blocks unclassified outside-employer Traditional catch-up instead of assuming sponsor Roth treatment" do
    employee.update!(date_of_birth: Date.new(1970, 1, 1))
    create_election(traditional_amount: 500, roth_amount: 0, catch_up_enabled: true)
    year_evidence(external_traditional_deferrals: 10_000)
    expect { calculate(ytd: ytd_before.merge(retirement: 15_000)) }.to raise_error(ArgumentError, /outside-employer Traditional/)
  end

  it "does not credit outside-employer Roth toward the current sponsor's Roth catch-up requirement" do
    employee.update!(date_of_birth: Date.new(1970, 1, 1))
    create_election(traditional_amount: 500, roth_amount: 0, catch_up_enabled: true)
    year_evidence(wages: 150_001, external_roth_deferrals: 8_000)
    calculate(ytd: ytd_before.merge(retirement: 16_500))
    expect(payroll_item.retirement_payment).to eq(0)
  end

  it "requires verified plan availability for legacy employee Roth contributions" do
    employee.update!(roth_retirement_rate: 0.05)
    expect { calculate }.to raise_error(ArgumentError, /plan permits designated Roth employee/)
  end

  it "requires verified provider support for legacy Roth employer matching" do
    employee.update!(employer_roth_match_rate: 0.05)
    expect { calculate }.to raise_error(ArgumentError, /provider reporting in an effective retirement plan election/)
  end

  it "requires verified support for flexible Roth employer fields" do
    employer_field
    expect { calculate }.to raise_error(ArgumentError, /provider reporting in an effective retirement plan election/)
  end

  it "requires verified support for recurring Roth employer deductions" do
    deduction = employer_deduction
    expect { calculate(deductions: [ deduction ]) }.to raise_error(ArgumentError, /provider reporting in an effective retirement plan election/)
  end

  it "permits flexible Roth employer contributions only with explicit plan and provider evidence" do
    create_election(traditional_amount: 0, roth_amount: 0)
    employer_field
    deduction = employer_deduction
    calculate(deductions: [ deduction ])
    expect(payroll_item.retirement_rule_snapshot.dig("annual_additions", "current_employer")).to eq("200.0")
  end

  it "blocks flexible employer percentage fields when gross crosses the annual compensation ceiling" do
    employer_field(group: "401k_pre_tax", percentage: true)
    expect { calculate(ytd: ytd_before.merge(gross_pay: 359_000)) }.to raise_error(ArgumentError, /verified capped employer-match election/)
  end

  it "blocks recurring employer percentages above the compensation ceiling even when additions are below their limit" do
    deduction = employer_deduction(group: "401k_pre_tax", percentage: true)
    expect { calculate(ytd: ytd_before.merge(gross_pay: 360_000), deductions: [ deduction ]) }.to raise_error(ArgumentError, /annual compensation ceiling/)
  end

  it "does not assume gross percentage fields use a verified restricted matching basis" do
    create_election(traditional_amount: 0, roth_amount: 0, eligible_compensation: "gross_excluding_tips")
    payroll_item.update!(reported_tips: 500)
    employer_field(group: "401k_pre_tax", percentage: true)
    expect { calculate(ytd: ytd_before.merge(gross_pay: 0)) }.to raise_error(ArgumentError, /outside the permitted compensation basis/)
  end

  it "allows flexible employer percentages within the gross compensation ceiling" do
    employer_field(group: "401k_pre_tax", percentage: true)
    calculate(ytd: ytd_before.merge(gross_pay: 358_000))
    expect(payroll_item.retirement_rule_snapshot.dig("annual_additions", "current_employer")).to eq("100.0")
  end

  it "shows no catch-up capacity for a verified high earner whose plan offers no designated Roth" do
    employee.update!(date_of_birth: Date.new(1970, 1, 1))
    create_election(traditional_amount: 500, roth_amount: 0, roth_available: false, catch_up_enabled: true)
    year_evidence(wages: 150_001)
    calculate(ytd: ytd_before.merge(retirement: 24_500))
    expect(payroll_item.retirement_payment).to eq(0)
    expect(payroll_item.retirement_rule_snapshot).to include("catch_up_permission_status" => "roth_unavailable",
      "catch_up_limit" => "0.0", "annual_employee_cap" => "24500.0", "remaining_after" => "0.0")
  end

  it "separates potential age eligibility from unverified permitted catch-up capacity" do
    employee.update!(date_of_birth: Date.new(1965, 1, 1))
    create_election(traditional_amount: 500, roth_amount: 0, catch_up_enabled: true)
    calculate
    expect(payroll_item.retirement_rule_snapshot).to include("catch_up_permission_status" => "prior_wages_pending",
      "catch_up_limit" => "0.0", "potential_catch_up_limit" => "11250.0", "annual_employee_cap" => "24500.0")
  end

  it "does not carry an old election's opening employer additions into another year" do
    create_election(effective_on: Date.new(2025, 1, 1), traditional_amount: 500, roth_amount: 0,
      employer_match_ytd_before_system: 72_000)
    calculate
    expect(payroll_item.retirement_rule_snapshot.dig("annual_additions", "prior_additions")).to eq("0.0")
  end

  it "preserves original version-one historical true-up compensation instead of defaulting to current pay" do
    election = create_election(traditional_amount: 200, roth_amount: 0,
      employer_match_mode: "compensation_percentage", employer_match_rate: 0.05, true_up_policy: "year_to_date")
    snapshot = { "version" => 1, "employee_age_at_year_end" => 46, "employer_match" => { "prior_ytd" => "2000.0" } }
    described_class.new(employee: employee, payroll_item: payroll_item, ytd_before: ytd_before,
      employee_deductions: [], historical_mode: true, historical_evidence: snapshot,
      historical_election: election.snapshot_attributes, historical_limit: { elective_deferral_limit: 24_500,
        catch_up_limit: 8_000, enhanced_catch_up_limit: 11_250, roth_catch_up_wage_threshold: 150_000 }).apply!
    expect(payroll_item.employer_retirement_match).to eq(100)
  end

  %i[regular_plan_deferral_limit plan_annual_employee_limit].each do |attribute|
    it "honors an explicit zero #{attribute} while nil means no additional cap" do
      create_election(traditional_amount: 500, roth_amount: 0, attribute => 0)
      calculate
      expect(payroll_item.retirement_payment).to eq(0)
    end
  end

  %i[employer_match_deferral_cap_rate employer_match_period_cap employer_match_annual_cap].each do |attribute|
    it "honors an explicit zero #{attribute} without paying an uncapped match" do
      create_election(traditional_amount: 500, roth_amount: 0, employer_match_mode: "employee_deferral_percentage",
        employer_match_rate: 1, attribute => 0)
      calculate
      expect(payroll_item.employer_retirement_match).to eq(0)
    end
  end

  it "retains version-one saved zero-as-uncapped semantics while new payroll honors zero caps" do
    election = create_election(traditional_amount: 200, roth_amount: 0, plan_annual_employee_limit: 0,
      employer_match_mode: "employee_deferral_percentage", employer_match_rate: 1,
      employer_match_period_cap: 0, employer_match_annual_cap: 0, employer_match_deferral_cap_rate: 0)
    described_class.new(employee: employee, payroll_item: payroll_item, ytd_before: ytd_before,
      employee_deductions: [], historical_mode: true, historical_evidence: { "version" => 1, "employee_age_at_year_end" => 46 },
      historical_election: election.snapshot_attributes, historical_limit: { elective_deferral_limit: 24_500,
        catch_up_limit: 8_000, enhanced_catch_up_limit: 11_250, roth_catch_up_wage_threshold: 150_000 }).apply!
    expect(payroll_item.retirement_payment).to eq(200)
    expect(payroll_item.employer_retirement_match).to eq(200)
  end
end
