# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll calculation with historical YTD" do
  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:employee) { create(:employee, company: company, pay_rate: 1_000, pay_frequency: "biweekly") }
  let!(:annual_config) do
    create(
      :annual_tax_config,
      tax_year: 2030,
      ss_wage_base: 184_500,
      ss_rate: 0.062,
      medicare_rate: 0.0145,
      additional_medicare_rate: 0.009,
      additional_medicare_threshold: 200_000,
      is_active: false
    )
  end
  let!(:filing_config) do
    create(:filing_status_config, annual_tax_config: annual_config, filing_status: "single", standard_deduction: 16_100)
  end

  before do
    create(:tax_bracket, filing_status_config: filing_config, bracket_order: 1, min_income: 0, max_income: nil, rate: 0.10)
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    bootstrap = HistoricalClientBootstrap.create!(
      company: company,
      historical_import_batch: batch,
      status: "applied",
      plan_digest: "bootstrap-plan",
      applied_at: Time.current,
      applied_by: actor
    )
    bridge = HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      status: "applied",
      plan_digest: "bridge-plan",
      preview_summary: {
        "through_period_end" => "2030-01-12",
        "through_pay_date" => "2030-01-17"
      },
      applied_at: Time.current,
      applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    )
    HistoricalEmployeeYtdBalance.create!(
      historical_ytd_bridge: bridge,
      company: company,
      employee: employee,
      tax_year: 2030,
      through_period_end: Date.new(2030, 1, 12),
      through_pay_date: Date.new(2030, 1, 17),
      gross_pay: 199_500,
      net_pay: 150_000,
      tips_paid_out: 100,
      reported_tips: 100,
      social_security_taxable_wages: 184_390,
      social_security_taxable_tips: 100,
      medicare_taxable_wages: 199_500
    )
  end

  it "uses the bridge for Social Security caps, Medicare thresholds, and displayed YTD without changing live snapshots" do
    period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2030, 1, 26),
      end_date: Date.new(2030, 2, 8),
      pay_date: Date.new(2030, 2, 14)
    )
    item = build(:payroll_item, company: company, employee: employee, pay_period: period, hours_worked: 1, pay_rate: 1_000)

    PayrollCalculator.for(employee, item).calculate

    expect(item.gross_pay).to eq(1_000.to_d)
    expect(item.social_security_taxable_wages + item.social_security_taxable_tips).to eq(10.to_d)
    expect(item.social_security_tax).to eq(0.62.to_d)
    expect(item.medicare_taxable_wages).to eq(1_000.to_d)
    expect(item.additional_medicare_taxable_wages).to eq(500.to_d)
    expect(item.additional_medicare_tax).to eq(4.50.to_d)
    expect(item.ytd_gross).to eq(200_500.to_d)
    expect(employee.ytd_totals_before(year: 2030, pay_date: period.pay_date, pay_period_id: period.id)).to include(
      tips_paid_out: 100.0,
      social_security_taxable_total: 184_490.0
    )
    expect(EmployeeYtdTotal.count).to eq(0)
    expect(CompanyYtdTotal.count).to eq(0)
  end

  it "ignores previewed historical balances until an authorized activation" do
    period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2030, 1, 26),
      end_date: Date.new(2030, 2, 8),
      pay_date: Date.new(2030, 2, 14)
    )
    HistoricalYtdBridge.find_by!(company: company).update_columns(
      status: "previewed",
      applied_at: nil,
      applied_by_id: nil,
      apply_acknowledgement: nil
    )
    item = build(:payroll_item, company: company, employee: employee, pay_period: period, hours_worked: 1, pay_rate: 1_000)

    PayrollCalculator.for(employee, item).calculate

    expect(item.social_security_taxable_wages + item.social_security_taxable_tips).to eq(1_000.to_d)
    expect(item.social_security_tax).to eq(62.to_d)
    expect(item.additional_medicare_tax).to eq(0.to_d)
    expect(item.ytd_gross).to eq(1_000.to_d)
  end

  it "uses later paycheck coverage when retained bridges were applied together" do
    original_applied_at = HistoricalYtdBridge.find_by!(plan_digest: "bridge-plan").applied_at
    later_batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    later_bootstrap = HistoricalClientBootstrap.create!(
      company: company,
      historical_import_batch: later_batch,
      status: "applied",
      plan_digest: "later-bootstrap",
      applied_at: original_applied_at,
      applied_by: actor
    )
    later_bridge = HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: later_batch,
      historical_client_bootstrap: later_bootstrap,
      status: "applied",
      plan_digest: "later-bridge",
      preview_summary: {
        "through_period_end" => "2030-01-19",
        "through_pay_date" => "2030-01-24"
      },
      applied_at: original_applied_at,
      applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    )
    HistoricalEmployeeYtdBalance.create!(
      historical_ytd_bridge: later_bridge,
      company: company,
      employee: employee,
      tax_year: 2030,
      through_period_end: Date.new(2030, 1, 19),
      through_pay_date: Date.new(2030, 1, 24),
      gross_pay: 210_000
    )

    expect(employee.calculate_ytd_gross(2030)).to eq(210_000.to_d)
  end

  it "uses the latest activation when retained bridges have the same coverage" do
    original_bridge = HistoricalYtdBridge.find_by!(plan_digest: "bridge-plan")
    original_bridge.update_column(:applied_at, 2.days.ago)
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    bootstrap = HistoricalClientBootstrap.create!(
      company: company,
      historical_import_batch: batch,
      status: "applied",
      plan_digest: "reactivated-bootstrap",
      applied_at: 1.day.ago,
      applied_by: actor
    )
    bridge = HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      status: "applied",
      plan_digest: "reactivated-bridge",
      preview_summary: original_bridge.preview_summary,
      applied_at: 1.day.ago,
      applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    )
    HistoricalEmployeeYtdBalance.create!(
      historical_ytd_bridge: bridge,
      company: company,
      employee: employee,
      tax_year: 2030,
      through_period_end: Date.new(2030, 1, 12),
      through_pay_date: Date.new(2030, 1, 17),
      gross_pay: 205_000
    )

    expect(employee.calculate_ytd_gross(2030)).to eq(205_000.to_d)
  end

  it "never selects a later historical balance from another company" do
    other_company = create(:company)
    other_employee = create(:employee, company: other_company, pay_rate: 1_000, pay_frequency: "biweekly")
    other_batch = create(:historical_import_batch, company: other_company, status: "locked", locked_at: Time.current)
    other_bootstrap = HistoricalClientBootstrap.create!(
      company: other_company,
      historical_import_batch: other_batch,
      status: "applied",
      plan_digest: "other-company-bootstrap",
      applied_at: Time.current,
      applied_by: actor
    )
    other_bridge = HistoricalYtdBridge.create!(
      company: other_company,
      historical_import_batch: other_batch,
      historical_client_bootstrap: other_bootstrap,
      status: "applied",
      plan_digest: "other-company-bridge",
      preview_summary: {
        "through_period_end" => "2030-02-28",
        "through_pay_date" => "2030-03-05"
      },
      applied_at: Time.current,
      applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    )
    HistoricalEmployeeYtdBalance.create!(
      historical_ytd_bridge: other_bridge,
      company: other_company,
      employee: other_employee,
      tax_year: 2030,
      through_period_end: Date.new(2030, 2, 28),
      through_pay_date: Date.new(2030, 3, 5),
      gross_pay: 999_999
    )

    expect(employee.calculate_ytd_gross(2030)).to eq(199_500.to_d)
    expect(other_employee.calculate_ytd_gross(2030)).to eq(999_999.to_d)
  end

  it "rejects a preloaded historical balance from the wrong tax year" do
    wrong_year_balance = HistoricalEmployeeYtdBalance.find_by!(employee: employee)
    wrong_year_balance.tax_year = 2029

    expect do
      employee.merge_historical_ytd({}, 2030, historical_balance: wrong_year_balance, preloaded: true)
    end.to raise_error(ArgumentError, /tax year does not match/)
  end
end
