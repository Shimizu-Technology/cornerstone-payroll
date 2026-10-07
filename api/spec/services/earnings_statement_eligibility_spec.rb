# frozen_string_literal: true

require "rails_helper"

RSpec.describe EarningsStatementEligibility do
  def printable(attributes = {})
    item = build(:payroll_item, { gross_pay: 0, net_pay: 0, check_number: nil }.merge(attributes))
    described_class.printable?(item)
  end

  it "includes earned wages entirely consumed by taxes and loan repayment" do
    expect(printable(gross_pay: 197.67, total_deductions: 197.67, loan_payment: 182.54)).to be true
  end

  it "includes salary without hours, tips, and reimbursement-only payments" do
    expect(printable(employment_type: "salary", hours_worked: 0, gross_pay: 1200)).to be true
    expect(printable(reported_tips: 50, gross_pay: 50)).to be true
    expect(printable(non_taxable_pay: 75, net_pay: 75)).to be true
  end

  it "includes negative correction activity and offsetting financial components" do
    expect(printable(gross_pay: -100, net_pay: -80, withholding_tax: -20)).to be true
    expect(printable(non_taxable_pay: 50, loan_payment: 50)).to be true
    expect(printable(employer_retirement_match: 25)).to be true
  end

  it "does not treat unprocessed hours as finalized earnings" do
    expect(printable(hours_worked: 80)).to be false
    expect(printable(hours_worked: 0)).to be false
    expect(printable(hours_worked: 0, loan_deduction: 50)).to be false
  end

  it "retains a legitimate numbered statement but never a voided one" do
    expect(printable(check_number: "8101")).to be true
    expect(printable(voided: true, gross_pay: 1200, check_number: "8101")).to be false
  end

  it "includes persisted financial rows while ignoring inactive field entries" do
    item = build(:payroll_item, gross_pay: 0, net_pay: 0)
    item.payroll_item_earnings.build(category: "other", label: "Correction", amount: -50)
    expect(described_class.printable?(item)).to be true

    empty_item = build(:payroll_item, gross_pay: 0, net_pay: 0)
    allow(empty_item).to receive(:payroll_item_field_entries).and_return([
      instance_double(PayrollItemFieldEntry, active?: false, amount: 75.to_d)
    ])
    expect(described_class.printable?(empty_item)).to be false
  end
end
