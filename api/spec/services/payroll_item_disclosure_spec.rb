# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollItemDisclosure do
  it "discloses saved recurring additions and all deduction sources without consulting changed defaults" do
    company = create(:company)
    employee = create(:employee, company:)
    period = create(:pay_period, company:)
    item = create(:payroll_item, company:, employee:, pay_period: period,
      gross_pay: 1_350, net_pay: 1_051, total_deductions: 399,
      withholding_tax: 100, additional_withholding: 25, social_security_tax: 62,
      medicare_tax: 19, additional_medicare_tax: 4.50,
      bonus: 250, retirement_payment: 40, loan_payment: 50, insurance_payment: 20,
      custom_deductions: [ { label: "Union", amount: 3 } ],
      payroll_adjustments: [
        { label: "Recurring bonus", amount: 100, treatment: "taxable_addition", active: true },
        { label: "Mileage", amount: 100, treatment: "non_taxable_addition", active: true },
        { label: "Installment", amount: 80, treatment: "post_tax_deduction", active: true },
        { label: "Inactive", amount: 999, treatment: "post_tax_deduction", active: false }
      ],
      custom_columns_data: { "payroll_adjustments_source" => "employee_default" })
    employee.update!(default_payroll_adjustments: [ { label: "Changed later", amount: 9_999, treatment: "taxable_addition" } ])

    result = described_class.new(item).as_json

    expect(result[:earnings]).to include(hash_including(label: "Recurring bonus", amount: 100, source: "employee_default"), hash_including(label: "Bonus", amount: 250, source: "one_time"))
    expect(result[:deductions].map { |entry| entry[:label] }).to include("Installment", "Union", "Loan", "Health Insurance", "401(k) Pre-Tax")
    expect(result.to_s).not_to include("Changed later", "Inactive")
    totals = result[:reconciliation]
    expect(totals[:employee_taxes]).to eq(206)
    expect(totals[:gross_pay] + totals[:other_pay] - totals[:employee_taxes] - totals[:other_deductions]).to eq(totals[:net_pay])
    expect(result[:deductions].sum { |line| line[:amount] }).to eq(193)
  end
  it "reconciles actual calculated earnings, reimbursements and deductions exactly once" do
    company = create(:company)
    employee = create(:employee, company:)
    period = create(:pay_period, company:, start_date: "2030-01-01", end_date: "2030-01-14", pay_date: "2030-01-18")
    config = create(:annual_tax_config, tax_year: 2030)
    filing = create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 0)
    create(:tax_bracket, filing_status_config: filing, bracket_order: 1, min_income: 0, max_income: nil, rate: 0.10)
    item = build(:payroll_item, company:, employee:, pay_period: period, hours_worked: 40, pay_rate: 25,
      bonus: 250, non_taxable_pay: 100, custom_earnings: [ { label: "Shift pay", amount: 50 } ],
      payroll_adjustments: [
        { label: "Recurring bonus", amount: 100, treatment: "taxable_addition" },
        { label: "Mileage", amount: 100, treatment: "non_taxable_addition" },
        { label: "Installment", amount: 80, treatment: "post_tax_deduction" }
      ])
    PayrollCalculator.for(employee, item).calculate
    item.save!

    result = described_class.new(item.reload).as_json
    expect(result[:earnings].sum { |line| line[:amount] }).to eq(item.gross_pay.to_f)
    expect(result[:earnings].map { |line| line[:label] }).not_to include("Mileage", "Non-Taxable Pay")
    expect(result[:other_pay].sum { |line| line[:amount] }).to eq(200)
    expect(result[:deductions].sum { |line| line[:amount] }.to_d + PayrollTaxSummary.new(item).total).to eq(item.total_deductions)
    expect(item.gross_pay + 200 - item.total_deductions).to eq(item.net_pay)
  end
end
