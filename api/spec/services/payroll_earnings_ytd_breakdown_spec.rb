# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollEarningsYtdBreakdown do
  include HistoricalYtdBridgeFixtureHelper

  let(:company) { create(:company, name: "MoSa's Migration Test") }
  let(:employee) { create(:employee, company: company, first_name: "Ayana", last_name: "Joint", employment_type: "hourly") }
  let(:pay_date) { Date.new(2026, 9, 24) }
  let(:pay_period) do
    create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 20), pay_date: pay_date)
  end
  let(:payroll_item) do
    create(:payroll_item, pay_period: pay_period, company: company, employee: employee,
      employment_type: "hourly", pay_rate: 11, hours_worked: 10.70,
      gross_pay: 117.70, net_pay: 108.69)
  end

  def apply_historical_balance(employee:, gross_pay:, earnings:, through_pay_date: Date.new(2026, 9, 10))
    apply_historical_ytd_balance(
      company: company,
      employee: employee,
      through_period_end: Date.new(2026, 9, 6),
      through_pay_date: through_pay_date,
      gross_pay: gross_pay,
      source_breakdown: { "earnings_breakdown" => earnings.transform_values(&:to_s) }
    )
  end

  it "adds Ayana's locked QuickBooks Joint earnings to the current rehearsal amount" do
    apply_historical_balance(employee: employee, gross_pay: 915.20, earnings: { "Joint" => 915.20 })
    payroll_item.payroll_item_earnings.create!(
      category: "regular", label: "Joint", hours: 10.70, rate: 11, amount: 117.70)

    row = described_class.new(payroll_item).call.sole

    expect(row).to have_attributes(label: "Joint", current: 117.70.to_d, ytd: 1_032.90.to_d)
  end

  it "keeps Monique's salary, bonus, and tips separate while carrying their QuickBooks YTD" do
    monique = create(:employee, company: company, first_name: "Monique", last_name: "Amani", employment_type: "salary")
    apply_historical_balance(
      employee: monique,
      gross_pay: 191_150.93,
      earnings: {
        "Salary" => 171_619.84,
        "Bonus" => 17_630.29,
        "Paycheck Tips" => 1_900.80
      }
    )
    item = create(:payroll_item, pay_period: pay_period, company: company, employee: monique,
      employment_type: "salary", gross_pay: 9_527.02, reported_tips: 120.22)
    item.payroll_item_earnings.create!(category: "salary", label: "Salary", amount: 8_478.89)
    item.payroll_item_earnings.create!(category: "tips", label: "Tips", amount: 120.22)
    item.payroll_item_earnings.create!(category: "other", label: "BONUS [1522/1]", amount: 927.91)

    rows = described_class.new(item).call.index_by(&:source_label)

    expect(rows.fetch("Salary")).to have_attributes(current: 8_478.89.to_d, ytd: 180_098.73.to_d)
    expect(rows.fetch("Tips")).to have_attributes(label: "Paycheck Tips", current: 120.22.to_d, ytd: 2_021.02.to_d)
    expect(rows.fetch("BONUS [1522/1]")).to have_attributes(current: 927.91.to_d, ytd: 18_558.20.to_d)
    expect(rows.values.sum(0.to_d, &:current)).to eq(9_527.02.to_d)
    expect(rows.values.sum(0.to_d, &:ytd)).to eq(200_677.95.to_d)
  end

  it "uses an exact label match before semantic fallback so distinct bonus rows do not collapse" do
    apply_historical_balance(employee: employee, gross_pay: 100, earnings: { "Bonus" => 100 })
    payroll_item.update!(gross_pay: 30)
    payroll_item.payroll_item_earnings.create!(category: "bonus", label: "Bonus", amount: 10)
    payroll_item.payroll_item_earnings.create!(category: "other", label: "BONUS [SPECIAL]", amount: 20)

    rows = described_class.new(payroll_item).call.index_by(&:source_label)

    expect(rows.fetch("Bonus").ytd).to eq(110.to_d)
    expect(rows.fetch("BONUS [SPECIAL]").ytd).to eq(20.to_d)
  end

  it "keeps prior-only earnings visible with zero current pay" do
    earlier_period = create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 8, 24), end_date: Date.new(2026, 9, 6), pay_date: Date.new(2026, 9, 10))
    earlier = create(:payroll_item, pay_period: earlier_period, company: company, employee: employee,
      employment_type: "hourly", gross_pay: 75)
    earlier.payroll_item_earnings.create!(category: "bonus", label: "Referral Bonus", amount: 75)
    payroll_item.payroll_item_earnings.create!(category: "regular", label: "Joint", amount: 117.70)

    rows = described_class.new(payroll_item).call.index_by(&:source_label)

    expect(rows.fetch("Referral Bonus")).to have_attributes(current: 0.to_d, ytd: 75.to_d, hours: nil, rate: nil)
    expect(rows.values.sum(0.to_d, &:ytd)).to eq(192.70.to_d)
  end

  it "keeps punctuation-distinct live earning labels separate" do
    earlier_period = create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 8, 24), end_date: Date.new(2026, 9, 6), pay_date: Date.new(2026, 9, 10))
    earlier = create(:payroll_item, pay_period: earlier_period, company: company, employee: employee,
      employment_type: "hourly", gross_pay: 25)
    earlier.payroll_item_earnings.create!(category: "other", label: "Shift+A", amount: 25)
    payroll_item.update!(gross_pay: 40)
    payroll_item.payroll_item_earnings.create!(category: "other", label: "Shift A", amount: 40)

    rows = described_class.new(payroll_item).call.index_by(&:source_label)

    expect(rows.fetch("Shift+A")).to have_attributes(current: 0.to_d, ytd: 25.to_d)
    expect(rows.fetch("Shift A")).to have_attributes(current: 40.to_d, ytd: 40.to_d)
  end

  it "uses the historical through-pay date as the cutoff for local payroll" do
    cutoff = Date.new(2026, 9, 10)
    overlapping_period = create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 8, 24), end_date: Date.new(2026, 9, 6), pay_date: cutoff)
    overlapping = create(:payroll_item, pay_period: overlapping_period, company: company, employee: employee,
      employment_type: "hourly", gross_pay: 100)
    overlapping.payroll_item_earnings.create!(category: "regular", label: "Joint", amount: 100)
    apply_historical_balance(employee: employee, gross_pay: 100, earnings: { "Joint" => 100 }, through_pay_date: cutoff)
    payroll_item.payroll_item_earnings.create!(category: "regular", label: "Joint", amount: 117.70)

    expect(described_class.new(payroll_item).call.sole.ytd).to eq(217.70.to_d)
  end

  it "includes earlier reportable payroll, excludes voided and future payroll, and includes the current item once" do
    earlier_period = create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 8, 24), end_date: Date.new(2026, 9, 6), pay_date: Date.new(2026, 9, 10))
    earlier = create(:payroll_item, pay_period: earlier_period, company: company, employee: employee,
      employment_type: "hourly", gross_pay: 50)
    earlier.payroll_item_earnings.create!(category: "regular", label: "Joint", amount: 50)
    voided = create(:payroll_item, pay_period: create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 8, 10), end_date: Date.new(2026, 8, 23), pay_date: Date.new(2026, 8, 27)),
      company: company, employee: employee, employment_type: "hourly", gross_pay: 1_000, voided: true)
    voided.payroll_item_earnings.create!(category: "regular", label: "Joint", amount: 1_000)
    future_period = create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 9, 21), end_date: Date.new(2026, 10, 4), pay_date: Date.new(2026, 10, 8))
    future = create(:payroll_item, pay_period: future_period, company: company, employee: employee,
      employment_type: "hourly", gross_pay: 2_000)
    future.payroll_item_earnings.create!(category: "regular", label: "Joint", amount: 2_000)
    payroll_item.payroll_item_earnings.create!(category: "regular", label: "Joint", amount: 117.70)

    expect(described_class.new(payroll_item).call.sole.ytd).to eq(167.70.to_d)
  end
end
