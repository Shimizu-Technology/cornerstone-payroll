# frozen_string_literal: true

module CorrectivePayrollLedgerHelpers
  def original!(post_liabilities: true, track_ytd: true, **inputs)
    item = period.payroll_items.build(employee: employee, company: company, employment_type: "hourly", pay_rate: 15, hours_worked: 60, **inputs)
    PayrollCalculator.for(employee, item).calculate
    yield item if block_given?
    item.save!
    if track_ytd
      employee.ytd_totals_for(ledger_tax_year).add_payroll_item!(item)
      CompanyYtdTotal.find_or_create_by!(company: company, year: ledger_tax_year).add_payroll_item!(item)
    end
    PayrollLiabilityPostingService.post!(pay_period: period, actor: actor) if post_liabilities
    item.reload
  end

  def preview(inputs)
    IssueCorrectivePaycheckService.preview(original_pay_period: period, employee: employee, corrected_inputs: inputs, pay_date: ledger_correction_date)
  end

  def issue(inputs = {}, digest: nil, **overrides)
    inputs = inputs.merge(overrides)
    IssueCorrectivePaycheckService.issue!(original_pay_period: period, employee: employee, corrected_inputs: inputs,
      pay_date: ledger_correction_date, reason: "Component reconciliation", actor: actor, expected_review_digest: digest).last
  end

  def add_deduction(category:, sub_category:, reporting_group: nil, percentage: 5)
    type = DeductionType.create!(company: company, name: "Synthetic #{category} #{sub_category}", category: category,
      sub_category: sub_category, reporting_group: reporting_group)
    employee.employee_deductions.create!(deduction_type: type, amount: percentage, is_percentage: true, active: true)
    verify_synthetic_retirement_plan!(employee, period.pay_date) if sub_category == "retirement"
    type
  end

  def assert_cash(item)
    data = QuickbooksPayrollReportData.new(item.pay_period)
    deductions = data.pre_tax_retirement_deduction_lines_for(item).sum { |line| line.amount.to_d } +
      data.after_tax_deduction_lines_for(item).sum { |line| line.amount.to_d } + data.employee_tax_total(item).to_d
    expect(deductions.round(2)).to eq(item.total_deductions), "deduction detail"
    other = data.other_pay_lines_for(item).sum { |line| line.amount.to_d }
    expect((item.gross_pay + other - deductions).round(2)).to eq(item.net_pay), "cash reconciliation"
    earnings = data.earnings_lines_for(item).reject { |line| line.label == "Gross" }
    expect(earnings.sum { |line| line.amount.to_d }.round(2)).to eq(item.gross_pay), "taxable earnings detail"
  end

  def freeze_history(item)
    [ item.attributes, item.payroll_item_earnings.order(:id).map(&:attributes),
      item.payroll_item_deductions.order(:id).map(&:attributes), item.payroll_item_field_entries.order(:id).map(&:attributes) ]
  end
end

RSpec.shared_context "corrective payroll ledger fixtures" do |options = {}|
  include CorrectivePayrollLedgerHelpers

  let(:ledger_tax_year) { options.fetch(:tax_year, 2024) }
  let(:ledger_correction_date) { options.fetch(:correction_date) { Date.new(ledger_tax_year, 1, 26) } }
  let!(:tax_table) { create(:tax_table, tax_year: ledger_tax_year) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:employee) { create(:employee, company: company, pay_rate: 15, pay_frequency: "biweekly", filing_status: "single") }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:period) do
    create(:pay_period, :committed, company: company,
      start_date: options.fetch(:start_date) { Date.new(ledger_tax_year, 1, 1) },
      end_date: options.fetch(:end_date) { Date.new(ledger_tax_year, 1, 14) },
      pay_date: options.fetch(:pay_date) { Date.new(ledger_tax_year, 1, 19) })
  end
end
