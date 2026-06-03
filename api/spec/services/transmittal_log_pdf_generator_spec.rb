# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe TransmittalLogPdfGenerator do
  let(:company) { create(:company, name: "AIRE Services") }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }
  let(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 14),
      pay_date: Date.new(2026, 4, 16))
  end

  before do
    create(:payroll_item, :with_check,
      company: company,
      employee: employee,
      pay_period: pay_period,
      check_number: "1007",
      gross_pay: 1200.00,
      withholding_tax: 50.52,
      social_security_tax: 74.40,
      employer_social_security_tax: 74.40,
      medicare_tax: 17.40,
      employer_medicare_tax: 17.40)

    create(:non_employee_check,
      company: company,
      pay_period: pay_period,
      payable_to: "Treasurer of Guam",
      amount: 50.52,
      memo: "FIT Withholding - PPE 04/14/2026 - Form 500")
  end

  it "uses the transmittal date for Date while preserving pay date for Pay Day" do
    pdf = described_class.new(pay_period, transmittal_date: Date.new(2026, 4, 20)).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.first.text

    expect(text).to include("Date:             04/20/2026")
    expect(text).to include("Pay Day:          04/16/2026")
  end

  it "prints non-employee GRT check type in all caps" do
    pdf = described_class.new(pay_period).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.first.text

    expect(text).to include("Check for Treasurer of Guam (GRT)")
  end

  it "uses editable payroll check numbers when provided" do
    pdf = described_class.new(pay_period, payroll_check_numbers: %w[3001 3005 3006]).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.first.text.gsub(/\s+/, " ")

    expect(text).to include("Checks #: 3001, 3005-3006")
    expect(text).not_to include("1007")
  end

  it "prints exact check ranges without implying missing check numbers were issued" do
    create(:payroll_item, :with_check,
      company: company,
      employee: create(:employee, company: company),
      pay_period: pay_period,
      check_number: "1010",
      gross_pay: 100.00)
    create(:payroll_item, :with_check,
      company: company,
      employee: create(:employee, company: company),
      pay_period: pay_period,
      check_number: "1011",
      gross_pay: 100.00)

    pdf = described_class.new(pay_period).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.first.text

    normalized_text = text.gsub(/\s+/, " ")

    expect(normalized_text).to include("Checks #: 1007, 1010-1011")
    expect(normalized_text).not_to include("1007 through 1011")
  end

  it "keeps a normal pay-period transmittal on one page" do
    pdf = described_class.new(
      pay_period,
      preparer_name: "Cornerstone Tax Services",
      notes: [
        "FICA Obligation (Social Security & Medicare): $183.60",
        "EFTPS payment to be done by client"
      ]
    ).generate
    reader = PDF::Reader.new(StringIO.new(pdf))

    expect(reader.page_count).to eq(1)
    expect(reader.pages.first.text).to include("Documents Provided to Client")
    expect(reader.pages.first.text).to include("Employer Tax Obligations")
  end
end
