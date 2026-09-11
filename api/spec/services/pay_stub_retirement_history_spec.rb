# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Pay stub retirement history" do
  let(:company) { create(:company, name: "Historical Stub Test") }
  let(:employee) { create(:employee, company: company, first_name: "Sample", last_name: "Employee") }
  let(:pay_date) { Date.new(2026, 4, 17) }
  let(:period) { create(:pay_period, :committed, company: company, pay_date: pay_date) }
  let(:item) { create(:payroll_item, employee: employee, pay_period: period, ytd_retirement: 0, ytd_roth_retirement: 0) }

  def add_field(paycheck, label:, amount:, retirement: true, roth: false)
    treatment = roth || !retirement ? "post_tax_deduction" : "pre_tax_deduction"
    paycheck.payroll_item_field_entries.create!(label: label, amount: amount, kind: "deduction", source: "manual",
      tax_treatment: treatment, category: retirement ? "retirement" : "rent",
      reporting_group: retirement ? (roth ? "401k_after_tax" : "401k_pre_tax") : nil)
  end

  def prior_item(date:, status: "committed", amount: 0)
    previous_period = create(:pay_period, company: company, status: status, pay_date: date)
    create(:payroll_item, employee: employee, pay_period: previous_period, retirement_payment: amount)
  end

  def historical_balance(date:, retirement:, roth:)
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    bootstrap = create(:historical_client_bootstrap, company: company, historical_import_batch: batch, status: "applied")
    actor = create(:user, company: company)
    bridge = HistoricalYtdBridge.create!(company: company, historical_import_batch: batch,
      historical_client_bootstrap: bootstrap, status: "applied", plan_digest: "stub-history", applied_at: Time.current,
      applied_by: actor, apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT,
      preview_summary: { "through_period_end" => date.iso8601, "through_pay_date" => date.iso8601 })
    HistoricalEmployeeYtdBalance.create!(historical_ytd_bridge: bridge, company: company, employee: employee,
      tax_year: date.year, through_period_end: date, through_pay_date: date, retirement: retirement, roth_retirement: roth)
  end

  it "renders prior and current saved contributions while leaving stale historical snapshots unchanged" do
    prior = prior_item(date: pay_date - 14)
    add_field(prior, label: "Earlier 401(k)", amount: 120)
    add_field(prior, label: "Earlier Roth", amount: 40, roth: true)
    add_field(item, label: "Current 401(k)", amount: 80)
    add_field(item, label: "Current Roth", amount: 20, roth: true)
    saved = [ prior, item ].map { |row| row.reload.attributes }
    generator = PayStubGenerator.new(item)
    text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")
    expect(text.lines.find { |line| line.include?("401(k) Retirement") }).to include("$80.00", "$200.00")
    expect(text.lines.find { |line| line.include?("Roth 401(k)") }).to include("$20.00", "$60.00")
    expect(generator.send(:ytd_total_deductions)).to eq(260)
    expect([ prior, item ].map { |row| row.reload.attributes }).to eq(saved)
  end

  it "retains earlier-only deductions and retirement after their current fields have been removed" do
    prior = prior_item(date: pay_date - 14)
    add_field(prior, label: "Old rent", amount: 100, retirement: false)
    add_field(prior, label: "Old 401(k)", amount: 90)
    generator = PayStubGenerator.new(item)
    expect(generator.send(:ytd_payroll_field_deductions_total)).to eq(100)
    expect(generator.send(:retirement_ytd_totals)).to include(retirement: 90)
    expect(generator.send(:ytd_total_deductions)).to eq(190)
  end

  it "excludes prior drafts, voided checks, later same-day runs, future payroll and other employees" do
    earlier = prior_item(date: pay_date, amount: 10)
    item
    prior_item(date: pay_date - 14, status: "draft", amount: 1000)
    prior_item(date: pay_date - 14, amount: 1000).update!(voided: true)
    prior_item(date: pay_date, amount: 1000)
    prior_item(date: pay_date + 14, amount: 1000)
    other_employee = create(:employee, company: company)
    create(:payroll_item, employee: other_employee, pay_period: earlier.pay_period, retirement_payment: 1000)
    add_field(item, label: "Current 401(k)", amount: 20)
    expect(PayStubGenerator.new(item).send(:retirement_ytd_totals)).to eq(retirement: 30, roth_retirement: 0)
  end

  it "adds a draft current paycheck once and one historical bridge before the stub cutoff" do
    prior_item(date: pay_date - 14, amount: 50)
    period.update!(status: "draft")
    add_field(item, label: "Current 401(k)", amount: 25)
    add_field(item, label: "Current Roth", amount: 10, roth: true)
    historical_balance(date: pay_date - 60, retirement: 500, roth: 100)
    historical_balance(date: pay_date + 14, retirement: 9000, roth: 9000)
    generator = PayStubGenerator.new(item)
    2.times { expect(generator.send(:retirement_ytd_totals)).to eq(retirement: 575, roth_retirement: 110) }
    expect(item.reload.ytd_retirement).to eq(0)
  end
end
