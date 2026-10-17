# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe SignedCorrectionEarnings do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company:) }
  let(:original_period) { create(:pay_period, :committed, company:) }
  let(:original) { create(:payroll_item, company:, employee:, pay_period: original_period, pay_rate: 25, hours_worked: 4, gross_pay: 100) }
  let(:period) do
    create(:pay_period, :committed, company:, cycle: "supplemental", run_purpose: "correction",
      run_purpose_source: "system_correction", includes_base_salary: false, includes_recurring_items: false,
      corrects_pay_period_id: original_period.id)
  end
  let(:item) do
    create(:payroll_item, company:, employee:, pay_period: period, correction_for_payroll_item: original,
      pay_rate: 25, hours_worked: -1, overtime_hours: 0, holiday_hours: 0, pto_hours: 0,
      bonus: 0, reported_tips: 0, custom_earnings: [], gross_pay: -25,
      social_security_tax: -1.55, medicare_tax: -0.36, total_deductions: -1.91, net_pay: -23.09)
  end

  it "uses saved signed inputs consistently in disclosure and PDF without changing history" do
    employee.update!(pay_rate: 999)
    before = item.reload.attributes.deep_dup
    lines = described_class.call(item)
    expect(lines.map(&:label)).to eq([ "Regular adjustment" ])
    expect(lines.first).to have_attributes(hours: -1.to_d, rate: 25.to_d, amount: -25.to_d)
    disclosure = PayrollItemDisclosure.new(item).as_json
    expect(disclosure[:earnings]).to include(hash_including(label: "Regular adjustment", amount: -25.to_d))
    expect(disclosure[:earnings].sum { |line| line[:amount] }).to eq(item.gross_pay)
    text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join("\n")
    expect(text).to include("Regular adjustment", "-1.00", "$25.00", "$-25.00")
    expect(item.reload.attributes).to eq(before)
    expect(item.payroll_item_earnings.count).to eq(0)
  end

  it "retains signed REG and OT when their cent amounts exactly reconcile with gross" do
    item.update!(hours_worked: -2, overtime_hours: 1, gross_pay: -12.50)
    lines = described_class.call(item)
    expect(lines.map(&:amount)).to eq([ -50.to_d, 37.50.to_d ])
    expect(lines.sum(&:amount)).to eq(item.gross_pay)
  end

  it "uses an honest generic adjustment when the saved rate/hours do not explain gross" do
    item.update!(gross_pay: -30)
    line = described_class.call(item).sole
    expect(line).to have_attributes(label: "Taxable earnings adjustment", amount: -30.to_d, hours: nil, rate: nil, source: "correction_total")
    disclosure = PayrollItemDisclosure.new(item).as_json
    expect(disclosure[:earnings].sole[:amount]).to eq(-30.to_d)
    text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join("\n")
    expect(text).to include("Taxable earnings adjustment", "$-30.00")
    expect(text).not_to include("Regular adjustment")
  end

  it "does not double-count mixed scalar earnings after choosing the generic gross adjustment" do
    item.update!(reported_tips: 10)
    expect(described_class.call(item).sole.label).to eq("Taxable earnings adjustment")
    text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join("\n")
    expect(text).to include("Taxable earnings adjustment")
    expect(text).not_to include("Reported Tips", "Regular adjustment")
    expect(PayrollItemDisclosure.new(item).as_json[:earnings].sum { |line| line[:amount] }).to eq(item.gross_pay)
  end

  it "leaves materialized earning rows and ordinary payroll on their existing paths" do
    item.payroll_item_earnings.create!(category: "regular", label: "Retained category", hours: nil, rate: 25, amount: -25)
    expect(described_class.call(item)).to be_nil
    expect(PayrollItemDisclosure.new(item).as_json[:earnings].map { |line| line[:label] }).to include("Retained category")
    expect(described_class.call(original)).to be_nil
  end
end
