# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe PaycheckHistoryPdfGenerator do
  it "shows the saved source and treatment for paycheck adjustments" do
    company = create(:company)
    employee = create(:employee, company: company)
    pay_period = create(:pay_period, :committed, company: company)
    create(:payroll_item, company: company, employee: employee, pay_period: pay_period,
      payroll_adjustments: [ { "label" => "Employee loan", "amount" => 50, "treatment" => "post_tax_deduction" } ],
      custom_columns_data: {
        PayrollItem::PAYROLL_ADJUSTMENTS_SOURCE_KEY => PayrollItem::EMPLOYEE_DEFAULT_ADJUSTMENTS_SOURCE
      })

    text = PDF::Reader.new(StringIO.new(described_class.new(pay_period).generate)).pages.map(&:text).join("\n")

    expect(text).to include("Recurring and manual adjustment detail")
    expect(text).to include("Employee loan", "Post tax deduction", "Employee setup", "$50.00")
  end

  it "keeps adjustment detail for a voided paycheck shown in history" do
    company = create(:company)
    employee = create(:employee, company: company)
    pay_period = create(:pay_period, :committed, company: company)
    payroll_item = create(:payroll_item, company: company, employee: employee, pay_period: pay_period,
      payroll_adjustments: [ { "label" => "Voided loan", "amount" => 25, "treatment" => "post_tax_deduction" } ],
      custom_columns_data: {
        PayrollItem::PAYROLL_ADJUSTMENTS_SOURCE_KEY => PayrollItem::MANUAL_ADJUSTMENTS_SOURCE,
        "payroll_adjustments_overridden" => true
      })
    payroll_item.update!(voided: true)

    text = PDF::Reader.new(StringIO.new(described_class.new(pay_period).generate)).pages.map(&:text).join("\n")

    expect(text).to include("Voided loan", "Manual pay-period entry", "$25.00")
  end
  it "prints direct deposits and zero-net earnings without implying a missing check" do
    company = create(:company)
    period = create(:pay_period, :committed, company: company)
    create(:payroll_item, company: company, pay_period: period,
      employee: create(:employee, company: company), payment_delivery_method: "direct_deposit",
      check_number: nil, gross_pay: 900, net_pay: 700)
    create(:payroll_item, company: company, pay_period: period,
      employee: create(:employee, company: company), payment_delivery_method: "paper_check",
      check_number: nil, gross_pay: 197.67, net_pay: 0, loan_deduction: 182.54)
    create(:payroll_item, company: company, pay_period: period,
      employee: create(:employee, company: company), payment_delivery_method: "paper_check",
      check_number: "9001", gross_pay: 500, net_pay: 400, voided: true)

    text = PDF::Reader.new(StringIO.new(described_class.new(period).generate)).pages.map(&:text).join("\n")
      .gsub(/\s+/, " ")
    expect(text).to include("Direct deposit", "$0 net", "earnings", "statement only", "Paper check", "9001", "Voided")
    expect(text).not_to include("No check issued")
  end
end
