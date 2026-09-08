# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollAdjustmentExport do
  let(:workers) do
    [
      {
        payroll_adjustments: [
          { label: "Employee loan", treatment: "post_tax_deduction", source: "employee_default", amount: 50.0 },
          { label: "Mileage", treatment: "non_taxable_addition", source: "manual", amount: 20.0 }
        ]
      },
      {
        payroll_adjustments: [
          { label: "Employee loan", treatment: "post_tax_deduction", source: "employee_default", amount: 25.0 }
        ]
      }
    ]
  end

  subject(:export) { described_class.new(workers) }

  it "shares source-aware columns and worker values across report formats" do
    expect(export.headers).to contain_exactly(
      "Payroll Adjustment - Mileage (Non taxable addition; manual pay-period entry)",
      "Payroll Adjustment - Employee loan (Post tax deduction; employee setup snapshot)"
    )
    expect(export.values_for(workers.first).compact).to contain_exactly(20.0, 50.0)
    expect(export.values_for(workers.second).compact).to eq([ 25.0 ])
    expect(export.column_totals).to eq([ 20.0, 75.0 ])
  end

  it "groups totals without combining different treatments or sources" do
    expect(export.grouped_totals).to include(
      hash_including(label: "Employee loan", source: "employee_default", amount: 75.0),
      hash_including(label: "Mileage", source: "manual", amount: 20.0)
    )
  end
end
