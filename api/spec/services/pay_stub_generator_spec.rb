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
end
