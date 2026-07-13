# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollLiabilityBackfillService do
  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }
  let!(:legacy_period) do
    create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 6, 30)).tap do |period|
      create(:payroll_item,
        pay_period: period,
        employee: employee,
        company: company,
        withholding_tax: 50,
        social_security_tax: 25)
    end
  end

  it "previews eligible history without writing" do
    service = described_class.new(company: company, through_date: Date.new(2026, 12, 31))

    expect { @preview = service.preview }.not_to change(PayrollLiabilityPosting, :count)
    expect(@preview).to include(
      eligible_pay_period_ids: [ legacy_period.id ],
      eligible_count: 1,
      payroll_item_count: 1
    )
  end

  it "requires explicit confirmation" do
    service = described_class.new(company: company, through_date: Date.new(2026, 12, 31))

    expect { service.call }.to raise_error(described_class::ConfirmationRequiredError)
  end

  it "posts eligible periods once without changing payroll values" do
    service = described_class.new(company: company, through_date: Date.new(2026, 12, 31))
    before_values = legacy_period.payroll_items.first.attributes.slice(
      "gross_pay", "net_pay", "withholding_tax", "social_security_tax", "medicare_tax"
    )

    first = service.call(confirm: true)
    second = described_class.new(company: company, through_date: Date.new(2026, 12, 31)).call(confirm: true)

    expect(first).to include(posted_pay_period_ids: [ legacy_period.id ], posted_count: 1, errors: [])
    expect(second).to include(posted_pay_period_ids: [], posted_count: 0, errors: [])
    expect(legacy_period.payroll_items.first.reload.attributes.slice(*before_values.keys)).to eq(before_values)
  end

  it "excludes future, draft, voided, and other-company periods" do
    future_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2027, 1, 15))
    create(:payroll_item, pay_period: future_period, employee: employee, company: company, withholding_tax: 1)
    create(:pay_period, company: company, pay_date: Date.new(2026, 5, 1))
    voided = create(:pay_period, :voided, company: company, pay_date: Date.new(2026, 5, 15))
    create(:payroll_item, pay_period: voided, employee: employee, company: company, withholding_tax: 1)
    other_company = create(:company)
    other_department = create(:department, company: other_company)
    other_employee = create(:employee, company: other_company, department: other_department)
    other_period = create(:pay_period, :committed, company: other_company, pay_date: Date.new(2026, 5, 15))
    create(:payroll_item, pay_period: other_period, employee: other_employee, company: other_company, withholding_tax: 1)

    preview = described_class.new(company: company, through_date: Date.new(2026, 12, 31)).preview

    expect(preview[:eligible_pay_period_ids]).to eq([ legacy_period.id ])
  end
end
