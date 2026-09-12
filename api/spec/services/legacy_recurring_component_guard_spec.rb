# frozen_string_literal: true

require "rails_helper"

RSpec.describe LegacyRecurringComponentGuard do
  let(:employee) do
    create(
      :employee,
      default_payroll_adjustments: [
        { "label" => "Legacy stipend", "amount" => 50.0, "treatment" => "taxable_addition", "active" => true },
        { "label" => "Legacy rent", "amount" => 25.0, "treatment" => "post_tax_deduction", "active" => true }
      ],
      default_custom_earnings: [ { "label" => "Legacy earning", "amount" => 10.0 } ]
    )
  end

  it "allows unchanged legacy rows so unrelated employee edits keep working" do
    expect do
      described_class.validate!(
        employee: employee,
        payroll_adjustments: employee.default_payroll_adjustments,
        custom_earnings: employee.default_custom_earnings
      )
    end.not_to raise_error
  end

  it "allows legacy rows to be removed during typed-field migration" do
    expect do
      described_class.validate!(employee: employee, payroll_adjustments: employee.default_payroll_adjustments.first(1))
    end.not_to raise_error
  end

  it "rejects new or changed free-text recurring behavior" do
    changed = employee.default_payroll_adjustments.deep_dup
    changed.first["amount"] = 75

    expect do
      described_class.validate!(employee: employee, payroll_adjustments: changed)
    end.to raise_error(described_class::Error, /must use Assigned Payroll Fields/)
  end

  it "rejects new legacy custom earnings" do
    expect do
      described_class.validate!(employee: create(:employee), custom_earnings: [ { label: "Stipend", amount: 10 } ])
    end.to raise_error(described_class::Error, /legacy recurring earnings/)
  end
end
