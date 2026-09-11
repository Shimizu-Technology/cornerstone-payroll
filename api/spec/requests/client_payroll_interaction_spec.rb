# frozen_string_literal: true

require "rails_helper"

# Entirely synthetic identities, amounts and W-4 elections. This exercises a
# variable-salary workflow without publishing client payroll records.
RSpec.describe "Client payroll setting interactions", type: :request do
  let!(:company) { create(:company, name: "Local variable-pay scenario", pay_frequency: "biweekly") }
  let!(:admin) { create(:user, company: company, role: "admin") }
  let!(:period) { create(:pay_period, company: company, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 14), pay_date: Date.new(2026, 9, 18)) }
  let!(:owners) do
    [ 900.00, 1200.00 ].each_with_index.map do |amount, index|
      employee = create(:employee, company: company, first_name: "Owner", last_name: "Scenario #{index + 1}",
        employment_type: "salary", salary_type: "variable", pay_rate: 0, retirement_rate: 0,
        employer_retirement_match_rate: 0.04, roth_retirement_rate: 0, employer_roth_match_rate: 0,
        filing_status: "single", allowances: 0, w4_dependent_credit: 0, pay_frequency: "biweekly",
        default_payroll_adjustments: [ { label: "Recurring retirement-funding bonus", amount: amount, treatment: "taxable_addition", active: true } ])
      deduction = DeductionType.create!(company: company, name: "Owner #{index + 1} 401(k)", category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
      employee.employee_deductions.create!(deduction_type: deduction, amount: amount, active: true)
      employee
    end
  end

  before do
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: 2026)
    single = create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
    # IRS Publication 15-T (2026), annual standard table, single, Worksheet 1A.
    [ [ 0, 7500, 0 ], [ 7500, 19900, 0.10 ], [ 19900, 57900, 0.12 ], [ 57900, 113200, 0.22 ],
      [ 113200, 209275, 0.24 ], [ 209275, 263725, 0.32 ], [ 263725, 648100, 0.35 ], [ 648100, nil, 0.37 ] ].each_with_index do |(min, max, rate), index|
      create(:tax_bracket, filing_status_config: single, bracket_order: index + 1, min_income: min, max_income: max, rate: rate)
    end
    [ Api::V1::Admin::PayPeriodsController, Api::V1::Admin::ReportsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(controller).to receive(:current_user).and_return(admin)
    end
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(admin.id)
  end

  def run!(target = period, pay: 9000.00, bonuses: {})
    post "/api/v1/admin/pay_periods/#{target.id}/run_payroll", params: {
      employee_ids: owners.map(&:id), salary_overrides: owners.index_with { pay }.transform_keys { |e| e.id.to_s }, bonuses: bonuses
    }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors")).to be_empty
    target.reload.payroll_items.order(:employee_id).to_a
  end

  def commit!(target)
    post "/api/v1/admin/pay_periods/#{target.id}/approve"
    expect(response).to have_http_status(:ok)
    post "/api/v1/admin/pay_periods/#{target.id}/commit"
    expect(response).to have_http_status(:ok)
  end

  it "keeps period pay, recurring bonus, pretax deduction, employer contribution and reports consistent" do
    items = run!
    # Independently calculated: FIT = 46,184.00 / 26 = 1,776.31 for
    # 9,000.00 FIT wages. FICA includes the retirement-funding bonus.
    expected = [
      { gross_pay: 9900.00, withholding_tax: 1776.31, social_security_tax: 613.80, medicare_tax: 143.55, net_pay: 6466.34, employer_retirement_match: 396.00 },
      { gross_pay: 10200.00, withholding_tax: 1776.31, social_security_tax: 632.40, medicare_tax: 147.90, net_pay: 6443.39, employer_retirement_match: 408.00 }
    ]
    items.zip(expected).each do |item, amounts|
      amounts.each { |field, value| expect(item.public_send(field)).to eq(value.to_d), "#{item.employee.full_name} #{field}" }
    end
    before = items.map { |item| item.attributes.slice("gross_pay", "net_pay", "total_deductions") }
    expect(run!.map { |item| item.attributes.slice("gross_pay", "net_pay", "total_deductions") }).to eq(before)
    commit!(period)
    owners.zip([ 900.00, 1200.00 ]).each do |owner, amount|
      expect(EmployeeYtdTotal.find_by!(employee: owner, year: 2026).retirement).to eq(amount.to_d)
    end
    get "/api/v1/admin/reports/w2_gu", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("report", "totals", "box12_code_d_total").to_d).to eq(2100.00.to_d)
    expect(response.parsed_body.dig("report", "totals", "box1_wages_tips_other_comp").to_d).to eq(18000.00.to_d)
    saved = period.payroll_items.order(:employee_id).map(&:attributes)
    owners.first.update!(default_payroll_adjustments: [])
    get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok)
    expect(period.payroll_items.reload.order(:employee_id).map(&:attributes)).to eq(saved)
    PayPeriodCorrectionService.void!(pay_period: period.reload, actor: admin, reason: "Local scenario reversal")
    expect(EmployeeYtdTotal.where(employee: owners, year: 2026).sum(:retirement)).to eq(0)
  end

  it "changes period pay without duplicating recurring amounts or carrying a one-time bonus into the next payroll" do
    first_items = run!(period, bonuses: { owners.first.id.to_s => 100 })
    expect(first_items.first.gross_pay).to eq(10000.00.to_d)
    expect(run!.first.bonus).to eq(100)
    expect(run!(period, bonuses: { owners.first.id.to_s => 0 }).first.gross_pay).to eq(9900.00.to_d)
    commit!(period)
    next_period = create(:pay_period, company: company, start_date: Date.new(2026, 9, 15), end_date: Date.new(2026, 9, 28), pay_date: Date.new(2026, 10, 2))
    second_items = run!(next_period, pay: 10300.00)
    expect(second_items.map(&:bonus)).to eq([ 0, 0 ])
    expect(second_items.map(&:gross_pay)).to eq([ 11200.00.to_d, 11500.00.to_d ])
    expect(second_items.map(&:ytd_retirement)).to eq([ 1800.00.to_d, 2400.00.to_d ])
    commit!(next_period)
    expect(EmployeeYtdTotal.where(employee: owners, year: 2026).sum(:retirement)).to eq(4200.00.to_d)
  end

  # This characterizes a remaining setup limitation, not a recommended off-cycle
  # policy: includes_base_salary does not control recurring additions/deductions.
  it "exposes recurring contributions that still require review on a no-base off-cycle run" do
    period.update!(run_purpose: "bonus", includes_base_salary: false)
    items = run!(period, pay: 0, bonuses: owners.to_h { |owner| [ owner.id.to_s, 7000 ] })
    expect(items.map(&:gross_pay)).to eq([ 7900.00.to_d, 8200.00.to_d ])
    expect(items.map { |item| PayrollRetirementTotals.for_item(item)[:retirement] }).to eq([ 900.00.to_d, 1200.00.to_d ])
  end
end
