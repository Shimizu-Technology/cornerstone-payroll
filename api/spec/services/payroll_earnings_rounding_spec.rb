# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Saved payroll earnings rounding" do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:employee) { create(:employee, company: company, pay_rate: "10.50") }
  let(:period) { create(:pay_period, company: company, pay_date: Date.new(2024, 1, 19)) }

  def calculate_buckets(hours, **inputs)
    item = period.payroll_items.build(employee: employee, company: company, employment_type: employee.employment_type,
      pay_rate: "10.50", **inputs)
    item.wage_rate_hours = hours.each_with_index.map do |value, index|
      { label: "Source #{index}", rate: "10.50", regular_hours: value,
        overtime_hours: 0, holiday_hours: 0, pto_hours: 0, active: true }
    end
    captured = item.wage_rate_hours.deep_dup
    PayrollCalculator.for(employee, item).calculate
    item.save!
    expect(item.reload.wage_rate_hours).to eq(captured)
    item
  end

  def assert_totals(item, gross:, other: 0)
    taxable, non_taxable = item.payroll_item_earnings.partition { |row| !row.category.in?(%w[non_taxable reimbursement]) }
    expect(taxable.sum(&:amount)).to eq(gross.to_d)
    expect(item.gross_pay).to eq(gross.to_d)
    expect(non_taxable.sum(&:amount)).to eq(other.to_d)
    expect(item.gross_pay + other.to_d - item.total_deductions).to eq(item.net_pay)
  end

  it "saves two 0.01-hour buckets at $10.50 as $0.11 each and gross $0.22" do
    item = calculate_buckets([ "0.01", "0.01" ])
    assert_totals(item, gross: "0.22")
    expect(item.payroll_item_earnings.map(&:amount)).to eq([ "0.11".to_d, "0.11".to_d ])
  end

  it "sums many saved buckets without accumulating a hidden fractional-cent residual" do
    assert_totals(calculate_buckets(Array.new(101, "0.01")), gross: "11.11")
  end

  it "recalculates uncommitted pre-deploy amounts using the saved-line policy" do
    item = calculate_buckets([ "0.01", "0.01" ])
    item.update_columns(gross_pay: "0.21", net_pay: "0.20",
      calculation_context_snapshot: item.calculation_context_snapshot.except("earnings_rounding"))
    period.update!(status: "calculated")
    item.reload.calculate!
    assert_totals(item.reload, gross: "0.22")
    expect(item.calculation_context_snapshot["earnings_rounding"]).to eq("saved_lines_v1")
  end

  it "preserves current, carryover and signed reversal hours and rounded amounts" do
    item = calculate_buckets([ "1.01", "0.01", "-0.01" ])
    assert_totals(item, gross: "10.61")
    expect(item.payroll_item_earnings.map(&:amount)).to eq([ "10.61".to_d, "0.11".to_d, "-0.11".to_d ])
  end

  it "includes bonus, tips and taxable additions while reconciling reimbursements and cash deductions separately" do
    item = calculate_buckets([ "0.01", "0.01" ], bonus: 5, reported_tips: 4, tips_paid_out: 2,
      service_charge_wages: 3, non_taxable_pay: 7,
      custom_earnings: [ { "label" => "Commission", "amount" => 6 } ],
      custom_deductions: [ { "label" => "Uniform", "amount" => 1 } ],
      payroll_adjustments: [ { "label" => "Travel", "amount" => 8, "treatment" => "non_taxable_addition" },
        { "label" => "Shift", "amount" => 2, "treatment" => "taxable_addition" } ])
    assert_totals(item, gross: "20.22", other: 15)
    data = QuickbooksPayrollReportData.new(period)
    expect(data.earnings_lines_for(item).reject { |row| row.label == "Gross" }.sum { |row| row.amount.to_d }).to eq(item.gross_pay)
    expect(data.other_pay_lines_for(item).sum { |row| row.amount.to_d }).to eq(15)
  end

  context "an hourly contractor" do
    let(:employee) { create(:employee, :contractor, company: company, pay_rate: "10.50", contractor_pay_type: "hourly") }

    it "uses the same monetary boundary for frozen buckets" do
      assert_totals(calculate_buckets([ "0.01", "0.01" ]), gross: "0.22")
    end
  end

  it "rounds single-rate regular, overtime, holiday and PTO lines before summing gross" do
    item = period.payroll_items.build(employee: employee, company: company, employment_type: "hourly", pay_rate: "10.50",
      hours_worked: "0.01", overtime_hours: "0.01", holiday_hours: "0.01", pto_hours: "0.01")
    PayrollCalculator.for(employee, item).calculate
    item.save!
    assert_totals(item.reload, gross: "0.49")
  end
end
