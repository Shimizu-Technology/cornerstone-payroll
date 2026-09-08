# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnnualPayrollSummary do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:user) { create(:user, company: company, role: "admin") }

  def historical_paycheck(status:, suffix:, year:, employee:, gross_pay:, net_pay:)
    batch = create(
      :historical_import_batch,
      company: company,
      status: status,
      source_label: "QuickBooks #{suffix}",
      bundle_digest: Digest::SHA256.hexdigest("annual-summary-#{suffix}")
    )
    batch.update_columns(locked_at: Time.current, locked_by_id: user.id) if status == "locked"
    pay_date = Date.new(year, 6, 15)
    period = HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "period-#{suffix}",
      source_label: "Payroll #{suffix}",
      start_date: pay_date - 13.days,
      end_date: pay_date - 5.days,
      pay_date: pay_date,
      period_type: "regular",
      paycheck_count: 1,
      totals: { "gross_pay" => gross_pay.to_s, "net_pay" => net_pay.to_s }
    )
    worker = create(
      :historical_worker,
      historical_import_batch: batch,
      company: company,
      employee: employee,
      external_key: "worker-#{suffix}",
      source_name: employee&.full_name || "Unlinked Worker",
      mapping_status: employee ? "exact_match" : "archive_only"
    )
    paycheck = HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      company: company,
      employee: employee,
      external_key: "paycheck-#{suffix}",
      source_employee_name: employee&.full_name || "Unlinked Worker",
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: employee ? "matched" : "unmatched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: pay_date,
      hours_total: 40,
      gross_pay: gross_pay,
      adjusted_gross: gross_pay - 20,
      pretax_deductions: 20,
      employee_taxes: 100,
      federal_income_tax: 40,
      social_security_tax: 50,
      medicare_tax: 10,
      after_tax_deductions: 30,
      net_pay: net_pay,
      employer_taxes: 38,
      employer_contributions: 15,
      total_payroll_cost: gross_pay + 53
    )
    [ batch, period, paycheck ]
  end

  it "breaks locked QuickBooks and committed Cornerstone payroll totals out by year" do
    native_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 7, 1))
    native_item = create(
      :payroll_item,
      company: company,
      employee: employee,
      pay_period: native_period,
      hours_worked: 80,
      gross_pay: 1_000,
      non_taxable_pay: 25,
      withholding_tax: 100,
      additional_withholding: 10,
      social_security_tax: 62,
      medicare_tax: 14.50,
      additional_medicare_tax: 1,
      retirement_payment: 50,
      roth_retirement_payment: 25,
      custom_deductions: [ { "label" => "Allotment", "amount" => 10 } ],
      net_pay: 747.50,
      employer_social_security_tax: 62,
      employer_medicare_tax: 14.50,
      employer_retirement_match: 40
    )
    pre_tax = DeductionType.create!(company: company, category: "pre_tax", name: "Health", active: true)
    loan = DeductionType.create!(company: company, category: "post_tax", sub_category: "loan", name: "Loan", active: true)
    employer_match = DeductionType.create!(company: company, category: "employer_contribution", name: "401(k) Match", active: true)
    PayrollItemDeduction.create!(payroll_item: native_item, deduction_type: pre_tax, category: "pre_tax", label: "Health", amount: 20)
    PayrollItemDeduction.create!(payroll_item: native_item, deduction_type: loan, category: "post_tax", label: "Loan", amount: 30)
    PayrollItemDeduction.create!(payroll_item: native_item, deduction_type: employer_match, category: "employer_contribution", label: "401(k) Match", amount: 40)

    _batch, _period, imported = historical_paycheck(
      status: "locked", suffix: "linked-2025", year: 2025, employee: employee, gross_pay: 500, net_pay: 350
    )
    historical_paycheck(status: "locked", suffix: "unlinked-2025", year: 2025, employee: nil, gross_pay: 250, net_pay: 180)
    historical_paycheck(status: "previewed", suffix: "preview-2024", year: 2024, employee: employee, gross_pay: 9_999, net_pay: 8_000)
    HistoricalPaycheckAdjustment.create!(
      company: company,
      historical_paycheck: imported,
      created_by: user,
      kind: "correction",
      effective_pay_date: imported.pay_date,
      filing_year: 2025,
      filing_quarter: 2,
      reason: "Correct source evidence after review",
      idempotency_key: "annual-summary-adjustment-#{company.id}",
      hours_total: 2,
      gross_pay: 100,
      adjusted_gross: 95,
      pretax_deductions: 5,
      pretax_deduction_breakdown: [ { "label" => "Health", "amount" => "5" } ],
      employee_taxes: 10,
      federal_income_tax: 10,
      employee_tax_breakdown: [ { "label" => "FIT", "amount" => "10" } ],
      after_tax_deductions: 10,
      after_tax_deduction_breakdown: [ { "label" => "Loan", "amount" => "10" } ],
      net_pay: 75,
      employer_taxes: 7,
      employer_tax_breakdown: [ { "label" => "Employer FICA", "amount" => "7" } ],
      employer_contributions: 5,
      employer_contribution_breakdown: [ { "label" => "Match", "amount" => "5" } ],
      total_payroll_cost: 112
    )

    report = described_class.new(company: company).call

    expect(report[:years].pluck(:year)).to eq([ 2026, 2025 ])
    native = report[:years].first
    expect(native).to include(
      payroll_count: 1,
      paycheck_count: 1,
      employee_count: 1,
      cornerstone_payroll_count: 1,
      quickbooks_payroll_count: 0,
      gross_pay: 1_000.0,
      non_taxable_pay: 25.0,
      adjusted_gross: 930.0,
      pretax_deductions: 70.0,
      employee_taxes: 186.5,
      after_tax_deductions: 65.0,
      net_pay: 747.5,
      employer_taxes: 76.5,
      employer_contributions: 40.0,
      total_payroll_cost: 1_141.5
    )

    imported_year = report[:years].second
    expect(imported_year).to include(
      quickbooks_payroll_count: 1,
      quickbooks_paycheck_count: 1,
      adjustment_count: 1,
      excluded_unlinked_paycheck_count: 1,
      excluded_unlinked_gross_pay: 250.0,
      hours: 42.0,
      gross_pay: 600.0,
      adjusted_gross: 575.0,
      pretax_deductions: 25.0,
      employee_taxes: 110.0,
      after_tax_deductions: 40.0,
      net_pay: 425.0,
      employer_taxes: 45.0,
      employer_contributions: 20.0,
      total_payroll_cost: 665.0
    )
    expect(report[:totals]).to include(
      year_count: 2,
      employee_count: 1,
      gross_pay: 1_600.0,
      net_pay: 1_172.5,
      total_payroll_cost: 1_806.5,
      excluded_unlinked_paycheck_count: 1
    )
    expect(report[:source_statement]).to include("never rewrite the source")
  end

  it "returns a stable empty report when no payroll is available" do
    report = described_class.new(company: company).call

    expect(report[:years]).to eq([])
    expect(report[:totals]).to include(year_count: 0, payroll_count: 0, paycheck_count: 0, employee_count: 0)
    expect(report[:totals][:gross_pay]).to eq(0.0)
  end
end
