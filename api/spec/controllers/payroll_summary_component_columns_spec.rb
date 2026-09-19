# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::Admin::ReportsController do
  subject(:controller) { described_class.new }

  it "keeps same-label employee fields and adjustments in distinct report columns" do
    entries = [
      { employee_id: 1, label: "Allowance", tax_treatment: "taxable_addition", payroll_field_definition_id: 10, amount: 25 },
      { employee_id: 2, label: "Allowance", tax_treatment: "taxable_addition", payroll_field_definition_id: 11, amount: 30 },
      { employee_id: 1, employee_name: "Ana", payroll_item_id: 100, position: 0, label: "Allowance", treatment: "taxable_addition", amount: 5 }
    ]

    columns = controller.send(:period_summary_component_columns, entries, [ 1, 2 ])

    expect(columns.length).to eq(3)
    expect(columns.map { |column| column[:key] }.uniq.length).to eq(3)
    expect(controller.send(:period_summary_component_values, columns, 1).values).to contain_exactly(25, 5)
    expect(controller.send(:period_summary_component_values, columns, 2).values).to eq([ 30 ])
  end
end
