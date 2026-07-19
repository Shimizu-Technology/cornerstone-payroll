# frozen_string_literal: true

require "rails_helper"

RSpec.describe UnifiedTransmittalBootstrapService do
  let(:company) { create(:company, name: "Mosa's Hotbox") }
  let(:actor) { create(:user, company: company, name: "Dafne") }
  let(:pay_period) do
    create(:pay_period, :calculated,
      company: company,
      start_date: Date.new(2026, 6, 14),
      end_date: Date.new(2026, 6, 27),
      pay_date: Date.new(2026, 7, 3))
  end
  let(:employee) { create(:employee, company: company, first_name: "Maria", last_name: "Santos") }

  before do
    create(:payroll_item, :with_check,
      pay_period: pay_period,
      employee: employee,
      withholding_tax: 42.00,
      additional_withholding: 8.00,
      social_security_tax: 74.40,
      medicare_tax: 17.40)
    create(:non_employee_check, :with_check_number,
      company: company,
      pay_period: pay_period,
      payable_to: "Treasurer of Guam",
      amount: 50.00)
  end

  subject(:service) { described_class.new(pay_period: pay_period, actor: actor) }

  it "builds one editable packet from checks, reports, and calculated obligations" do
    transmittal = service.call

    expect(transmittal).to be_pay_period_source
    expect(transmittal.pay_period).to eq(pay_period)
    expect(transmittal.items.pluck(:source_key)).to include(
      a_string_starting_with("payroll_item:"),
      a_string_starting_with("non_employee_check:"),
      "report:payroll_register",
      "tax_obligation:income_tax"
    )

    income_tax = transmittal.items.find_by!(source_key: "tax_obligation:income_tax")
    expect(income_tax.amount).to eq(50.00)
    expect(income_tax.metadata).to include("calculated_only" => true)
    expect(income_tax.details.join(" ")).to include("Payment is not recorded")
  end

  it "is idempotent and preserves operator edits while appending new source rows" do
    first = service.call
    report = first.items.find_by!(source_key: "report:payroll_register")
    report.update!(title: "CEO payroll register", included: false)

    second = service.call

    expect(second.id).to eq(first.id)
    expect(second.items.where(source_key: "report:payroll_register").count).to eq(1)
    expect(second.items.find_by!(source_key: "report:payroll_register")).to have_attributes(
      title: "CEO payroll register",
      included: false
    )
  end
end
