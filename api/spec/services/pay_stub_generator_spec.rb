# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe PayStubGenerator do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, name: "Stub Company") }
  let(:pay_period) { create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 4, 15)) }
  let(:employee) do
    create(
      :employee,
      company: company,
      first_name: "Pat",
      last_name: "Stub",
      employment_type: "hourly",
      pay_rate: 20
    )
  end

  let(:payroll_item) do
    create(
      :payroll_item,
      pay_period: pay_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      bonus: 50,
      reported_tips: 25,
      custom_earnings: [ { "label" => "Chief Stipend", "amount" => 75 } ],
      custom_deductions: [ { "label" => "Cash Advance", "amount" => 40 } ],
      gross_pay: 310,
      net_pay: 250,
      ytd_gross: 310,
      ytd_net: 250
    )
  end

  it "prints supplemental earnings even when stored earning rows are partial" do
    payroll_item.payroll_item_earnings.create!(
      category: "regular",
      label: "Regular Pay",
      hours: 8,
      rate: 20,
      amount: 160
    )

    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Regular Pay")
    expect(text).to include("Bonus")
    expect(text).to include("Reported Tips")
    expect(text).to include("Chief Stipend")
  end

  it "prints custom deductions by label" do
    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Cash Advance")
  end

  it "prints treatment-aware payroll adjustments by label without duplicating non-taxable earnings" do
    payroll_item.update!(
      payroll_adjustments: [
        { "label" => "Taxable Bonus", "amount" => 100.0, "treatment" => "taxable_addition", "active" => true },
        { "label" => "Reimbursement", "amount" => 25.0, "treatment" => "non_taxable_addition", "active" => true },
        { "label" => "Pre-Tax Deduction", "amount" => 10.0, "treatment" => "pre_tax_deduction", "active" => true },
        { "label" => "Post-Tax Deduction", "amount" => 15.0, "treatment" => "post_tax_deduction", "active" => true }
      ]
    )
    payroll_item.payroll_item_earnings.create!(category: "non_taxable", label: "Reimbursement", amount: 25.0)

    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Taxable Bonus")
    expect(text).to include("NON-TAXABLE ADDITIONS")
    expect(text.scan("Reimbursement").count).to eq(1)
    expect(text).to include("Pre-Tax Deduction")
    expect(text).to include("Post-Tax Deduction")
  end

  it "does not include later same-pay-date custom deductions in YTD custom deduction totals" do
    later_period = create(
      :pay_period,
      :committed,
      company: company,
      pay_date: pay_period.pay_date
    )
    create(
      :payroll_item,
      pay_period: later_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      custom_deductions: [ { "label" => "Cash Advance", "amount" => 60 } ],
      total_deductions: 60,
      gross_pay: 160,
      net_pay: 100
    )

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")

    expect(text).to include("Cash Advance")
    expect(text).to include("$40.00")
    expect(text).not_to include("$100.00")
  end

  it "keeps a standard earnings statement to one page" do
    payroll_item.payroll_item_earnings.create!(
      category: "regular",
      label: "Regular Pay",
      hours: 8,
      rate: 20,
      amount: 160
    )

    pdf = described_class.new(payroll_item).generate

    expect(PDF::Reader.new(StringIO.new(pdf)).page_count).to eq(1)
  end

  it "prints the generated timestamp in Guam time" do
    travel_to Time.utc(2026, 4, 29, 19, 48) do
      pdf = described_class.new(payroll_item).generate
      text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

      expect(text).to include("Generated on April 30, 2026 at 05:48 AM ChST")
    end
  end

  it "lets dense earnings statements flow to additional content pages without a footer-only page" do
    120.times do |index|
      payroll_item.payroll_item_earnings.create!(
        category: "other",
        label: "Supplemental Earning #{index + 1}",
        amount: 10 + index
      )
    end

    pdf = described_class.new(payroll_item).generate
    pages = PDF::Reader.new(StringIO.new(pdf)).pages

    expect(pages.count).to be > 1
    expect(pages.last.text).to include("Supplemental Earning 120")
    expect(pages.last.text).to include("Generated on")
  end
end
