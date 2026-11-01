# frozen_string_literal: true

require "rails_helper"

# Staging item 289: a $175 contractor paycheck with no tax, deduction,
# contribution or loan, legacy-voided in a committed period that still has an
# unpaid FIT deposit check and an unrelated reimbursement check.
RSpec.describe ReversePaycheckService, "shared liability payments" do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:employee) { create(:employee, company: company, pay_rate: 15, pay_frequency: "biweekly", allowances: 0) }
  let(:intern) { create(:employee, :contractor, company: company) }
  let(:shared_message) { "This payroll has shared liability payments; reconcile them before reversing one paycheck" }
  let(:legacy_reason) { "Check not issued; intern was intended to be removed from this pay period before processing." }

  let!(:taxed_item) do
    row = period.payroll_items.build(employee: employee, employment_type: "hourly", pay_rate: 15, hours_worked: 60)
    PayrollCalculator.for(employee, row).calculate
    row.save!
    row
  end
  let!(:intern_item) do
    create(:payroll_item, pay_period: period, employee: intern, employment_type: "contractor",
      pay_rate: 175, hours_worked: 0, gross_pay: 175, net_pay: 175)
  end
  let!(:fit_deposit) do
    NonEmployeeCheck.create!(company: company, pay_period: period, payable_to: "Treasurer of Guam",
      amount: taxed_item.withholding_tax, check_type: "tax_deposit", payment_method: "check", check_number: "2694",
      auto_generated_type: NonEmployeeCheck::AUTO_GENERATED_TYPES[:fit_deposit], memo: "FIT Withholding · Form 500")
  end
  let!(:reimbursement) do
    NonEmployeeCheck.create!(company: company, pay_period: period, payable_to: "Don Jones", amount: 2830.26,
      check_type: "reimbursement", payment_method: "check", check_number: "2399",
      memo: "Reimbursement for aircraft parts")
  end

  before do
    expect(taxed_item.withholding_tax).to be_positive
    company.assign_check_numbers!([ taxed_item, intern_item ])
    [ taxed_item, intern_item ].each { |row| add_to_ytd(row.reload) }
  end

  def add_to_ytd(row)
    row.employee.ytd_totals_for(2024).add_payroll_item!(row)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(row)
  end

  def legacy_void!(row)
    row.update!(voided: true, voided_at: Time.current, void_reason: legacy_reason)
    row.check_events.create!(user: actor, event_type: "voided", check_number: row.check_number, reason: row.void_reason)
  end

  def company_ytd
    CompanyYtdTotal.find_by!(company: company, year: 2024)
  end

  def period_liability_total
    period.payroll_liability_postings.joins(:entries).sum("payroll_liability_entries.amount")
  end

  def state_snapshot
    {
      items: period.payroll_items.order(:id).map(&:attributes),
      payments: [ fit_deposit, reimbursement ].map { |payment| payment.reload.attributes },
      employee_ytd: EmployeeYtdTotal.where(year: 2024).order(:id).map(&:attributes),
      company_ytd: company_ytd.attributes,
      postings: PayrollLiabilityPosting.count,
      entries: PayrollLiabilityEntry.count
    }
  end

  it "reverses a zero-liability contractor paycheck while unrelated FIT and reimbursement checks remain open" do
    legacy_void!(intern_item)
    expect(LegacyCheckVoidDetection.items).to include(intern_item)
    payments_before = [ fit_deposit, reimbursement ].map { |payment| payment.reload.attributes }
    taxed_before = taxed_item.reload.attributes
    intern_ytd_before = intern.ytd_totals_for(2024).reload.attributes.slice("gross_pay", "net_pay")
    company_before = company_ytd.attributes.slice("gross_pay", "net_pay", "withholding_tax")
    expect(period.payroll_liability_postings).to be_empty

    ReversePaycheckService.call(payroll_item: intern_item, actor: actor, reason: legacy_reason)

    expect(intern_item.reload).not_to be_payroll_included
    expect(LegacyCheckVoidDetection.items).not_to include(intern_item)
    expect(intern.ytd_totals_for(2024).reload.attributes.slice("gross_pay", "net_pay"))
      .to eq("gross_pay" => intern_ytd_before["gross_pay"] - 175, "net_pay" => intern_ytd_before["net_pay"] - 175)
    expect(company_ytd.attributes.slice("gross_pay", "net_pay", "withholding_tax"))
      .to eq("gross_pay" => company_before["gross_pay"] - 175, "net_pay" => company_before["net_pay"] - 175,
        "withholding_tax" => company_before["withholding_tax"])
    expect([ fit_deposit, reimbursement ].map { |payment| payment.reload.attributes }).to eq(payments_before)
    expect(taxed_item.reload.attributes).to eq(taxed_before)

    # The captured commit posting holds only the taxed paycheck's liabilities;
    # the paycheck offset is empty, so nothing is offset or posted twice.
    commit = period.payroll_liability_postings.find_by!(posting_type: "commit")
    offset = period.payroll_liability_postings.find_by!(posting_type: "paycheck_reversal")
    expect(commit.entries.distinct.pluck(:payroll_item_id)).to eq([ taxed_item.id ])
    expect(offset.entries).to be_empty
    expect(PayrollLiabilityEntry.where(payroll_item_id: intern_item.id)).to be_empty
    expect(commit.entries.find_by!(component_key: "guam_income_tax_withheld").amount).to eq(fit_deposit.amount)
    expect(period_liability_total).to eq(commit.entries.sum(:amount))
  end

  it "reverses a zero-liability paycheck while the FIT deposit reserves another paycheck's withholding" do
    PayrollLiabilityPostingService.post!(pay_period: period, actor: actor)
    withholding = period.payroll_liability_postings.first.entries.find_by!(payroll_item_id: taxed_item.id, component_key: "guam_income_tax_withheld")
    PayrollLiabilityCheckAllocationService.allocate!(non_employee_check: fit_deposit, entry_ids: [ withholding.id ])
    total_before = period_liability_total

    ReversePaycheckService.call(payroll_item: intern_item, actor: actor, reason: "Reverse unissued intern paycheck")

    expect(intern_item.reload).not_to be_payroll_included
    expect(fit_deposit.reload).not_to be_voided
    expect(fit_deposit.payroll_liability_check_allocations.pluck(:payroll_liability_entry_id)).to eq([ withholding.id ])
    expect(period_liability_total).to eq(total_before)
  end

  it "still blocks a paycheck with withholding while the period's FIT deposit is open" do
    before = state_snapshot
    expect { ReversePaycheckService.call(payroll_item: taxed_item, actor: actor, reason: "Reverse taxed paycheck") }
      .to raise_error(ArgumentError, shared_message)
    expect(state_snapshot).to eq(before)
  end

  it "still blocks a paycheck whose deduction is remitted by an open payee payment" do
    [ fit_deposit, reimbursement ].each { |payment| payment.void!(reason: "Isolate the payee payment") }
    payee = create(:employee, company: company)
    type = DeductionType.create!(company: company, name: "Child Support Order", category: "post_tax",
      sub_category: "child_support", payee_name: "Child Support Enforcement Division", active: true)
    deducted = create(:payroll_item, pay_period: period, employee: payee, gross_pay: 200, net_pay: 180, total_deductions: 20)
    deducted.payroll_item_deductions.create!(deduction_type: type, amount: 20, category: "post_tax", label: type.name)
    add_to_ytd(deducted)
    NonEmployeeCheck.create!(company: company, pay_period: period, payable_to: "Child Support Enforcement Division",
      amount: 20, check_type: "child_support", payment_method: "check", check_number: "2700")
    before = state_snapshot

    expect { ReversePaycheckService.call(payroll_item: deducted, actor: actor, reason: "Reverse deducted paycheck") }
      .to raise_error(ArgumentError, shared_message)
    expect(state_snapshot).to eq(before)
  end

  it "fails closed when a paycheck's gross-to-net difference is not explained by saved components" do
    intern_item.update_columns(net_pay: 160)
    before = state_snapshot
    expect { ReversePaycheckService.call(payroll_item: intern_item, actor: actor, reason: "Reverse unexplained paycheck") }
      .to raise_error(ArgumentError, shared_message)
    expect(state_snapshot).to eq(before)
  end

  it "fails closed when an open payment reserves a liability that is not attributed to any paycheck" do
    posting = PayrollLiabilityPostingService.post!(pay_period: period, actor: actor)
    entry = PayrollLiabilityEntry.create!(payroll_liability_posting: posting, company: company, payroll_item: nil,
      component_key: "unattributed:reimbursement", category: "other_payroll_liability", authority: "Don Jones", amount: 10)
    PayrollLiabilityCheckAllocation.create!(company: company, non_employee_check: reimbursement,
      payroll_liability_entry: entry, amount: 10)
    before = state_snapshot
    expect { ReversePaycheckService.call(payroll_item: intern_item, actor: actor, reason: "Reverse unissued intern paycheck") }
      .to raise_error(ArgumentError, shared_message)
    expect(state_snapshot).to eq(before)
  end

  it "still reverses a taxed paycheck once the open payments are voided" do
    [ fit_deposit, reimbursement ].each { |payment| payment.void!(reason: "Payments retired by operator") }
    ReversePaycheckService.call(payroll_item: taxed_item, actor: actor, reason: "Reverse taxed paycheck")
    expect(taxed_item.reload).not_to be_payroll_included
  end
end
