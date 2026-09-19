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
        tax_treatment: "taxable_addition", category: "other", amount: BigDecimal("10") * (index + 1)
      )
    end

    disclosure = described_class.new([ item ])
    expect(disclosure.totals.length).to eq(2)
    expect(disclosure.totals.map { |row| row.fetch(:amount) }).to contain_exactly(10, 20)
    expect(disclosure.totals.map { |row| row.fetch(:payroll_field_definition_id) }).to contain_exactly(*definitions.map(&:id))
  end

  it "sums fractional snapshot amounts without converting them to floats" do
    company = create(:company)
    period = create(:pay_period, company: company)
    definition = PayrollFieldDefinition.create!(
      company: company, name: "Allowance", kind: "addition", tax_treatment: "taxable_addition"
    )
    items = [ "0.10", "0.20" ].map do |amount|
      employee = create(:employee, company: company)
      item = create(:payroll_item, company: company, employee: employee, pay_period: period)
      item.payroll_item_field_entries.create!(
        payroll_field_definition: definition, label: "Allowance", kind: "addition",
        tax_treatment: "taxable_addition", category: "other", amount: BigDecimal(amount)
      )
      item
    end

    disclosure = described_class.new(items)

    expect(disclosure.rows.map { |row| row[:amount] }).to contain_exactly(BigDecimal("0.10"), BigDecimal("0.20"))
    expect(disclosure.totals.sole[:amount]).to eq(BigDecimal("0.30"))
    expect(disclosure.treatment_totals["taxable_addition"]).to eq(BigDecimal("0.30"))
  end
end
