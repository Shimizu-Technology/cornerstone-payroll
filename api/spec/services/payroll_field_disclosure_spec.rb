# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFieldDisclosure do
  it "retains two distinct definitions with the same visible name" do
    company = create(:company)
    employee = create(:employee, company: company)
    period = create(:pay_period, company: company)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period)
    definitions = [ "Allowance", "Allowance (renamed)" ].map do |name|
      PayrollFieldDefinition.create!(
        company: company,
        owner_employee: employee,
        name: name,
        kind: "addition",
        tax_treatment: "taxable_addition"
      )
    end
    definitions.each_with_index do |definition, index|
      item.payroll_item_field_entries.create!(
        payroll_field_definition: definition, label: "Allowance", kind: "addition",
        tax_treatment: "taxable_addition", category: "other", amount: (index + 1) * 10
      )
    end

    disclosure = described_class.new([ item ])
    expect(disclosure.totals.length).to eq(2)
    expect(disclosure.totals.map { |row| row.fetch(:amount) }).to contain_exactly(10, 20)
    expect(disclosure.totals.map { |row| row.fetch(:payroll_field_definition_id) }).to contain_exactly(*definitions.map(&:id))
  end
end
