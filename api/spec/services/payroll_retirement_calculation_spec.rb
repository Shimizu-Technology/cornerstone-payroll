# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollRetirementCalculation do
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

  def calculate(ytd: ytd_before, deductions: [])
    described_class.new(
      employee: employee,
      payroll_item: payroll_item,
      ytd_before: ytd,
      employee_deductions: deductions,
      recurring_items_enabled: true
    ).apply!
  end

  it "applies fixed traditional and Roth elections and preserves the rule evidence" do
    election = create_election

    calculate

    expect(payroll_item.retirement_payment).to eq(500)
    expect(payroll_item.roth_retirement_payment).to eq(250)
    expect(payroll_item.retirement_rule_snapshot).to include(
      "election" => include("election_id" => election.id, "plan_name" => "MoSa 401(k)"),
      "annual_limit" => include("elective_deferral_limit" => "24500.0"),
      "applied" => { "traditional" => "500.0", "roth" => "250.0" }
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

    calculate(ytd: ytd_before.merge(retirement: 24_500))

    expect(payroll_item.retirement_payment).to eq(11_250)
    expect(payroll_item.retirement_rule_snapshot["employee_age_at_year_end"]).to eq(61)
  end

  it "does not put a high-earner catch-up amount into traditional contributions" do
    employee.update!(date_of_birth: Date.new(1970, 6, 1))
    create_election(catch_up_enabled: true, traditional_amount: 500, roth_amount: 500, limit_priority: "traditional_first")
    allow(employee).to receive(:ytd_totals_through).and_return(social_security_taxable_total: 175_000)

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

  it "does not apply a future election before its first pay date" do
    create_election(effective_on: Date.new(2026, 10, 1))

    calculate

    expect(payroll_item.retirement_payment).to eq(0)
    expect(payroll_item.roth_retirement_payment).to eq(0)
    expect(payroll_item.retirement_rule_snapshot.dig("election", "source")).to eq("before_first_dated_election")
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
end
