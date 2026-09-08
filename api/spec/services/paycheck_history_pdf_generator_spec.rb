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
end
