# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form500Generator do
  it "includes W-4 Step 4(c) extra withholding in the default payment amount" do
    company = create(:company)
    department = create(:department, company: company)
    employee = create(:employee, company: company, department: department)
    period = create(:pay_period, :committed, company: company)
    create(:payroll_item,
      pay_period: period,
      employee: employee,
      company: company,
      withholding_tax: 100,
      additional_withholding: 25)

    fields = described_class.default_fields(company: company, pay_period: period)

    expect(fields[:total_taxes_dollars]).to eq("125")
    expect(fields[:total_taxes_cents]).to eq("00")
  end
end
