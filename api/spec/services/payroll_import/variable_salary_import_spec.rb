# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Variable salary source consistency" do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company) }
  let(:period) { create(:pay_period, company: company) }
  let!(:employee) do
    create(:employee, company: company, first_name: "Variable", last_name: "Salary",
      employment_type: "salary", salary_type: "variable", pay_rate: 200_000,
      default_payroll_adjustments: [ { "label" => "Recurring bonus", "amount" => 900.00, "treatment" => "taxable_addition", "active" => true } ])
  end
  let(:service) { PayrollImport::ImportService.new(period) }
  let(:source_row) { { employee_id: employee.id, regular_hours: 0, overtime_hours: 0, total_tips: 0, loan_deduction: 0 } }

  it "rejects the entire regular import before any employee is calculated when period pay is missing" do
    hourly = create(:employee, company: company, pay_rate: 10)
    rows = [ { employee_id: hourly.id, regular_hours: 40 }, source_row ]

    expect { service.apply!(matched: rows) }.to raise_error(ArgumentError, /Enter Pay this period.*Nothing has been imported/)
    expect(period.payroll_items.reload).to be_empty
    expect(period.reload.status).to eq("draft")
  end

  it "identifies missing period pay in preview without creating a payroll item" do
    preview = service.preview(pdf_records: [ { employee_name: "Salary, Variable", regular_hours: 0 } ], excel_records: [])
    expect(preview[:matched].first).to include(period_pay_required: true, period_pay_missing: true, overwrite_required: false)
    expect(period.payroll_items.reload).to be_empty
  end

  it "retains manually entered period pay, requires reviewed overwrite, and does not duplicate the recurring bonus" do
    item = period.payroll_items.build(employee: employee, employment_type: "salary", pay_rate: employee.pay_rate, salary_override: 9000.00)
    item.sync_default_payroll_adjustments!(employee)
    item.calculate!
    expect(item.gross_pay).to eq(9900.00)
    preview = service.preview(pdf_records: [ { employee_name: "Salary, Variable", regular_hours: 0 } ], excel_records: [])
    expect(preview[:matched].first).to include(period_pay_missing: false, current_period_pay: 9000.00, overwrite_required: true)
    expect(service.apply!(matched: [ source_row ])[:errors].first[:error]).to include("force_overwrite")
    expect(service.apply!(matched: [ source_row ], force_overwrite: true)[:errors]).to be_empty
    expect(item.reload.salary_override).to eq(9000.00)
    expect(item.gross_pay).to eq(9900.00)
    expect(service.apply!(matched: [ source_row ])[:errors]).to be_empty
    expect(item.reload.gross_pay).to eq(9900.00)
  end

  it "enforces period pay for direct calculation without treating a recurring bonus as base pay" do
    item = build(:payroll_item, pay_period: period, employee: employee, employment_type: "salary", pay_rate: employee.pay_rate)
    item.sync_default_payroll_adjustments!(employee)
    expect { item.calculate! }.to raise_error(ArgumentError, /Pay this period/)
    expect(item).not_to be_persisted
  end

  it "allows a tips-only import without period pay and excludes the salary base" do
    period.update!(run_purpose: "off_cycle_tips", includes_base_salary: false)
    employee.update!(default_payroll_adjustments: [])
    result = service.apply!(matched: [ source_row.merge(total_tips: 125) ])
    expect(result[:errors]).to be_empty
    item = period.payroll_items.find_by!(employee: employee)
    expect(item.salary_override).to be_nil
    expect(item.gross_pay).to eq(125)
  end
end
