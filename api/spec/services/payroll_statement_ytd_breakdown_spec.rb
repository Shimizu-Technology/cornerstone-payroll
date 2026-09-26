# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollStatementYtdBreakdown do
  include HistoricalYtdBridgeFixtureHelper

  let(:company) { create(:company, name: "MoSa's Migration Test") }
  let(:employee) { create(:employee, company: company, first_name: "Monique", last_name: "Amani", employment_type: "salary") }
  let(:pay_date) { Date.new(2026, 9, 24) }
  let(:pay_period) do
    create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 20), pay_date: pay_date)
  end
  let(:payroll_item) do
    create(:payroll_item, pay_period: pay_period, company: company, employee: employee,
      employment_type: "salary", gross_pay: 9_527.02, net_pay: 6_806.85)
  end

  def field_entry(item:, label:, amount:, treatment:, category:, reporting_group: nil)
    definition = create(:payroll_field_definition,
      company: company,
      name: label,
      kind: treatment == "employer_contribution" ? "employer_contribution" : treatment.include?("deduction") ? "deduction" : "addition",
      tax_treatment: treatment,
      category: category,
      reporting_group: reporting_group)
    create(:payroll_item_field_entry,
      payroll_item: item,
      payroll_field_definition: definition,
      label: label,
      amount: amount,
      kind: definition.kind,
      tax_treatment: treatment,
      category: category,
      reporting_group: reporting_group)
  end

  it "reuses payroll report data while building each statement section" do
    allow(QuickbooksPayrollReportData).to receive(:new).and_call_original
    breakdown = described_class.new(payroll_item)

    breakdown.deductions
    breakdown.other_pay
    breakdown.employer_contributions

    expect(QuickbooksPayrollReportData).to have_received(:new).once.with(pay_period)
  end

  it "carries migrated retirement, tips paid out, and employer match into one set of statement rows" do
    apply_historical_ytd_balance(
      company: company,
      employee: employee,
      through_period_end: Date.new(2026, 9, 6),
      through_pay_date: Date.new(2026, 9, 10),
      tips_paid_out: 1_900.80,
      source_breakdown: {
        "pretax_deduction_breakdown" => { "401(k) Pre-Tax" => "17630.29" },
        "after_tax_deduction_breakdown" => {},
        "employer_contribution_breakdown" => { "401(k) Pre-Tax" => "7646.04" }
      }
    )
    payroll_item.update!(retirement_payment: 927.91, employer_retirement_match: 381.08)

    result = described_class.new(payroll_item)
    deductions = result.deductions.index_by(&:semantic)
    employer = result.employer_contributions.index_by(&:semantic)

    expect(deductions.fetch(:"401k_pre_tax")).to have_attributes(
      label: "401(k) Pre-Tax", current: 927.91.to_d, ytd: 18_558.20.to_d)
    expect(deductions.fetch(:tips_paid_out)).to have_attributes(
      label: "Tips Paid Out", current: 0.to_d, ytd: 1_900.80.to_d)
    expect(employer.fetch(:"401k_pre_tax")).to have_attributes(
      current: 381.08.to_d, ytd: 8_027.12.to_d)
    expect(deductions.values.sum(0.to_d, &:ytd)).to eq(20_459.to_d)
  end

  it "does not display the legacy payout inferred from historical Pay Tip earnings" do
    balance = apply_historical_ytd_balance(
      company: company, employee: employee,
      through_period_end: Date.new(2026, 9, 6), through_pay_date: Date.new(2026, 9, 10),
      reported_tips: 1_900.80, tips_paid_out: 1_900.80,
      source_breakdown: { "earnings_breakdown" => { "Pay Tip" => "1900.80" } }
    )

    expect(described_class.new(payroll_item).deductions.map(&:semantic)).not_to include(:tips_paid_out)
    expect(balance.ytd_aggregate_totals.fetch(:tips_paid_out)).to eq(0.to_d)
    expect(balance.reload.tips_paid_out).to eq(1_900.80.to_d)
  end

  it "preserves a separately documented historical tip payout once" do
    balance = apply_historical_ytd_balance(
      company: company, employee: employee,
      through_period_end: Date.new(2026, 9, 6), through_pay_date: Date.new(2026, 9, 10),
      reported_tips: 100, tips_paid_out: 100,
      source_breakdown: {
        "earnings_breakdown" => { "Pay Tip" => "100" },
        "after_tax_deduction_breakdown" => { "Tip Payout" => "100" }
      }
    )

    expect(described_class.new(payroll_item).deductions.select { |row| row.semantic == :tips_paid_out }.sole.ytd).to eq(100.to_d)
    expect(balance.ytd_aggregate_totals.fetch(:tips_paid_out)).to eq(100.to_d)
  end

  it "matches migrated health and child support to differently worded current fields" do
    verna = create(:employee, company: company, first_name: "Verna", last_name: "John", employment_type: "hourly")
    apply_historical_ytd_balance(
      company: company,
      employee: verna,
      through_period_end: Date.new(2026, 9, 6),
      through_pay_date: Date.new(2026, 9, 10),
      source_breakdown: {
        "pretax_deduction_breakdown" => {},
        "after_tax_deduction_breakdown" => {
          "Health Insurance" => "2457.00",
          "Case No. 2952492" => "3024.00"
        },
        "employer_contribution_breakdown" => {}
      }
    )
    item = create(:payroll_item, pay_period: pay_period, company: company, employee: verna,
      employment_type: "hourly", gross_pay: 1_147.95)
    field_entry(item: item, label: "Health Insurance", amount: 126, treatment: "post_tax_deduction", category: "insurance")
    field_entry(item: item, label: "Remittance ID 2952492", amount: 168, treatment: "post_tax_deduction", category: "child_support")

    rows = described_class.new(item).deductions.index_by(&:semantic)

    expect(rows.fetch(:insurance)).to have_attributes(current: 126.to_d, ytd: 2_583.to_d)
    expect(rows.fetch(:child_support)).to have_attributes(current: 168.to_d, ytd: 3_192.to_d)
  end

  it "carries Sara's migrated allotment, rent, and auto-loan reimbursements into Other Pay" do
    sara = create(:employee, company: company, first_name: "Sara", last_name: "Doctor", employment_type: "salary")
    apply_historical_ytd_balance(
      company: company,
      employee: sara,
      through_period_end: Date.new(2026, 9, 6),
      through_pay_date: Date.new(2026, 9, 10),
      source_breakdown: {
        "earnings_breakdown" => {
          "Reimb" => "7713.28",
          "Rent - Charlie" => "2400.00",
          "Auto Loan Reimbursem" => "1936.00"
        }
      }
    )
    item = create(:payroll_item, pay_period: pay_period, company: company, employee: sara,
      employment_type: "salary", gross_pay: 9_695.24)
    field_entry(item: item, label: "Allotment - Douglas", amount: 482.08, treatment: "non_taxable_addition", category: "allotment")
    field_entry(item: item, label: "Rent Reimbursement", amount: 150, treatment: "non_taxable_addition", category: "rent")
    field_entry(item: item, label: "Auto Loan Reimbursement", amount: 121, treatment: "non_taxable_addition", category: "reimbursement")

    rows = described_class.new(item).other_pay.index_by(&:label)

    expect(rows.fetch("Allotment - Douglas")).to have_attributes(current: 482.08.to_d, ytd: 8_195.36.to_d)
    expect(rows.fetch("Rent Reimbursement")).to have_attributes(current: 150.to_d, ytd: 2_550.to_d)
    expect(rows.fetch("Auto Loan Reimbursement")).to have_attributes(current: 121.to_d, ytd: 2_057.to_d)
  end

  it "prefers an explicit current reimbursement over the legacy allotment rename" do
    apply_historical_ytd_balance(
      company: company,
      employee: employee,
      through_period_end: Date.new(2026, 9, 6),
      through_pay_date: Date.new(2026, 9, 10),
      source_breakdown: { "earnings_breakdown" => { "Reimb" => "400.00" } }
    )
    field_entry(item: payroll_item, label: "Allotment", amount: 100,
      treatment: "non_taxable_addition", category: "allotment")
    field_entry(item: payroll_item, label: "Reimbursement", amount: 50,
      treatment: "non_taxable_addition", category: "reimbursement")

    rows = described_class.new(payroll_item).other_pay.index_by(&:label)

    expect(rows.fetch("Allotment")).to have_attributes(current: 100.to_d, ytd: 100.to_d)
    expect(rows.fetch("Reimbursement")).to have_attributes(current: 50.to_d, ytd: 450.to_d)
  end

  it "keeps an unmatched generic reimbursement separate instead of guessing an allotment rename" do
    apply_historical_ytd_balance(
      company: company,
      employee: employee,
      through_period_end: Date.new(2026, 9, 6),
      through_pay_date: Date.new(2026, 9, 10),
      source_breakdown: { "earnings_breakdown" => { "Reimb" => "375.00" } }
    )
    field_entry(item: payroll_item, label: "Allotment", amount: 100,
      treatment: "non_taxable_addition", category: "allotment")

    rows = described_class.new(payroll_item).other_pay.index_by(&:label)

    expect(rows.fetch("Allotment")).to have_attributes(current: 100.to_d, ytd: 100.to_d)
    expect(rows.fetch("Reimb")).to have_attributes(current: 0.to_d, ytd: 375.to_d)
  end

  it "keeps a negative historical reimbursement separate from a current allotment" do
    apply_historical_ytd_balance(
      company: company,
      employee: employee,
      through_period_end: Date.new(2026, 9, 6),
      through_pay_date: Date.new(2026, 9, 10),
      source_breakdown: { "earnings_breakdown" => { "Reimb" => "-400.00" } }
    )
    field_entry(item: payroll_item, label: "Allotment", amount: 100,
      treatment: "non_taxable_addition", category: "allotment")

    rows = described_class.new(payroll_item).other_pay.index_by(&:label)

    expect(rows.fetch("Allotment")).to have_attributes(current: 100.to_d, ytd: 100.to_d)
    expect(rows.fetch("Reimb")).to have_attributes(current: 0.to_d, ytd: -400.to_d)
  end

  it "keeps distinct loans separate instead of guessing between ambiguous matches" do
    apply_historical_ytd_balance(
      company: company,
      employee: employee,
      through_period_end: Date.new(2026, 9, 6),
      through_pay_date: Date.new(2026, 9, 10),
      source_breakdown: {
        "pretax_deduction_breakdown" => {},
        "after_tax_deduction_breakdown" => {
          "Auto Loan" => "500.00",
          "Emergency Loan" => "750.00"
        }
      }
    )
    field_entry(item: payroll_item, label: "Auto Loan", amount: 25, treatment: "post_tax_deduction", category: "loan")
    field_entry(item: payroll_item, label: "Emergency Loan", amount: 40, treatment: "post_tax_deduction", category: "loan")

    rows = described_class.new(payroll_item).deductions.index_by(&:label)

    expect(rows.fetch("Auto Loan")).to have_attributes(current: 25.to_d, ytd: 525.to_d)
    expect(rows.fetch("Emergency Loan")).to have_attributes(current: 40.to_d, ytd: 790.to_d)
  end

  it "uses the historical cutoff and includes the current rehearsal item exactly once" do
    cutoff = Date.new(2026, 9, 10)
    overlapping_period = create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 8, 24), end_date: Date.new(2026, 9, 6), pay_date: cutoff)
    overlapping = create(:payroll_item, pay_period: overlapping_period, company: company, employee: employee,
      employment_type: "salary", retirement_payment: 999)
    apply_historical_ytd_balance(
      company: company,
      employee: employee,
      through_period_end: Date.new(2026, 9, 6),
      through_pay_date: cutoff,
      source_breakdown: {
        "pretax_deduction_breakdown" => { "401(k) Pre-Tax" => "100.00" },
        "after_tax_deduction_breakdown" => {}
      }
    )
    payroll_item.update!(retirement_payment: 25)

    row = described_class.new(payroll_item).deductions.find { |candidate| candidate.semantic == :"401k_pre_tax" }

    expect(row).to have_attributes(current: 25.to_d, ytd: 125.to_d)
    expect(overlapping.retirement_payment).to eq(999.to_d)
  end
end
