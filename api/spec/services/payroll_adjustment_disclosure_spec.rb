# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollAdjustmentDisclosure do
  let(:company) { create(:company) }
  let(:employee) do
    create(:employee, company: company, default_payroll_adjustments: [
      { "label" => "Changed later", "amount" => 999, "treatment" => "post_tax_deduction" }
    ])
  end
  let(:pay_period) { create(:pay_period, :committed, company: company) }

  def item_with(adjustments, source: nil)
    custom_columns_data = case source
    when "employee_default"
      { PayrollItem::PAYROLL_ADJUSTMENTS_SOURCE_KEY => PayrollItem::EMPLOYEE_DEFAULT_ADJUSTMENTS_SOURCE }
    when "manual"
      {
        PayrollItem::PAYROLL_ADJUSTMENTS_SOURCE_KEY => PayrollItem::MANUAL_ADJUSTMENTS_SOURCE,
        "payroll_adjustments_overridden" => true
      }
    else
      {}
    end

    create(:payroll_item, company: company, employee: employee, pay_period: pay_period,
      payroll_adjustments: adjustments, custom_columns_data: custom_columns_data)
  end

  it "reports only the active payroll-item snapshot and never current employee defaults" do
    item = item_with([
      { "label" => "Employee loan", "amount" => 50, "treatment" => "post_tax_deduction", "active" => true },
      { "label" => "Old loan", "amount" => 25, "treatment" => "post_tax_deduction", "active" => false }
    ], source: "employee_default")

    rows = described_class.new([ item ]).rows

    expect(rows.map { |row| row[:label] }).to eq([ "Employee loan" ])
    expect(rows.first).to include(source: "employee_default", kind: "deduction", employee_paid: true, amount: 50.0)
  end

  it "distinguishes manual and unmarked legacy snapshots" do
    manual = item_with([ { "label" => "Manual loan", "amount" => 50, "treatment" => "post_tax_deduction" } ], source: "manual")
    legacy_employee = create(:employee, company: company)
    legacy = create(:payroll_item, company: company, employee: legacy_employee, pay_period: pay_period,
      payroll_adjustments: [ { "label" => "Imported reimbursement", "amount" => 20, "treatment" => "non_taxable_addition" } ])

    rows = described_class.new([ manual, legacy ]).rows

    expect(rows.index_by { |row| row[:label] }).to include(
      "Manual loan" => hash_including(source: "manual"),
      "Imported reimbursement" => hash_including(source: "legacy_snapshot")
    )
  end

  it "reconciles row, grouped, and treatment totals without dropping equal labels" do
    first = item_with([ { "label" => "Loan", "amount" => 50, "treatment" => "post_tax_deduction" } ], source: "manual")
    second_employee = create(:employee, company: company)
    second = create(:payroll_item, company: company, employee: second_employee, pay_period: pay_period,
      payroll_adjustments: [ { "label" => "Loan", "amount" => 30, "treatment" => "post_tax_deduction" } ],
      custom_columns_data: { PayrollItem::PAYROLL_ADJUSTMENTS_SOURCE_KEY => PayrollItem::EMPLOYEE_DEFAULT_ADJUSTMENTS_SOURCE })

    disclosure = described_class.new([ first, second ])

    expect(disclosure.rows.sum { |row| row[:amount] }).to eq(80.0)
    expect(disclosure.totals.sum { |row| row[:amount] }).to eq(80.0)
    expect(disclosure.treatment_totals["post_tax_deduction"]).to eq(80.0)
    expect(disclosure.totals.map { |row| row[:source] }).to contain_exactly("employee_default", "manual")
  end
end
