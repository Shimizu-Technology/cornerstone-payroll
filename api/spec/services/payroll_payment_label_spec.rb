# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollPaymentLabel do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, payment_delivery_method: "paper_check") }
  let(:period) { create(:pay_period, :committed, company: company) }

  it "uses the committed direct-deposit snapshot despite a different employee default" do
    employee.update!(payment_delivery_method: "direct_deposit")
    item = create(:payroll_item, company: company, employee: employee, pay_period: period,
      payment_delivery_method: "direct_deposit", check_number: nil, net_pay: 700)
    employee.update!(payment_delivery_method: "paper_check")
    expect(described_class.for(item)).to eq("Direct deposit")
  end

  it "keeps old committed nil snapshots as paper checks instead of today's deposit default" do
    item = create(:payroll_item, company: company, employee: employee, pay_period: period,
      payment_delivery_method: nil, check_number: "400", net_pay: 700)
    employee.update!(payment_delivery_method: "direct_deposit")
    expect(described_class.for(item)).to eq("Paper check")
    expect(described_class.for(item)).not_to include("400")
  end

  it "distinguishes zero-net earnings from an unassigned positive check" do
    item = create(:payroll_item, company: company, employee: employee, pay_period: period,
      gross_pay: 197.67, net_pay: 0, loan_deduction: 182.54, check_number: nil)
    expect(described_class.for(item)).to eq(described_class::ZERO_NET)
    item.net_pay = 10
    expect(described_class.for(item)).to eq("Paper check · not assigned")
  end

  it "does not describe a negative-net corrective record as a deposit or check payment" do
    original = build(:payroll_item, company: company, employee: employee)
    correction = build(:payroll_item, company: company, employee: employee, pay_period: period,
      correction_for_payroll_item: original, payment_delivery_method: "direct_deposit", net_pay: -50)
    expect(described_class.for(correction)).to eq(described_class::ADJUSTMENT)
    correction.payment_delivery_method = "paper_check"
    correction.check_number = "400"
    expect(described_class.for(correction)).to eq(described_class::ADJUSTMENT)
    expect(described_class.history_row(record_type: "native", payment_delivery_method: "direct_deposit", net_pay: -50))
      .to eq(described_class::ADJUSTMENT)
  end

  it "preserves imported payment evidence and does not infer deposits from missing check numbers" do
    row = { record_type: "imported", payment_method: "Direct Deposit", net_pay: 100 }
    expect(described_class.history_row(row)).to eq("Direct deposit")
    expect(described_class.history_row(row.merge(payment_method: nil))).to eq("Not recorded")
    expect(described_class.history_row(row.merge(payment_method: "Cash"))).to eq("Cash")
    expect(described_class.history_row(row.merge(payment_method: nil, check_number: "23"))).to eq("Paper check")
  end

  it "does not imply payment for a historical adjustment" do
    expect(described_class.history_row(record_type: "adjustment", net_pay: 100)).to eq(described_class::ADJUSTMENT)
  end
end
