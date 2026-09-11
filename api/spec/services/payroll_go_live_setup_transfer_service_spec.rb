# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollGoLiveSetupTransferService do
  let(:organization) { create(:organization) }
  let(:source_company) { create(:company, organization:, name: "MoSa's predecessor", email: "old@example.com") }
  let(:company) { create(:company, organization:, name: "MoSa's successor", email: "new@example.com") }
  let(:actor) { create(:user, company:, organization:, role: "super_admin") }
  let(:effective_on) { Date.new(2026, 9, 21) }
  let(:batch) do
    create(:historical_import_batch, company:, status: "locked").tap do |record|
      create(:historical_client_bootstrap, company:, historical_import_batch: record, status: "applied")
    end
  end

  before do
    [ source_company, company ].each do |client|
      client.company_pay_schedules.create!(
        frequency: "biweekly",
        period_rule: client == source_company ? "biweekly" : "manual",
        period_start_weekday: client == source_company ? 1 : nil,
        period_anchor_date: client == source_company ? Date.new(2026, 1, 5) : nil,
        pay_date_rule: client == source_company ? "days_after_period_end" : "manual",
        pay_date_offset_days: client == source_company ? 5 : nil,
        timezone: "Pacific/Guam",
        effective_on: Date.new(2026, 1, 1),
        source: client == source_company ? "operator_confirmed" : "legacy_system_default",
        confirmation_status: client == source_company ? "confirmed" : "needs_confirmation",
        confirmed_by: client == source_company ? actor : nil,
        confirmed_at: client == source_company ? Time.current : nil,
        notes: client == source_company ? "Employer confirmed schedule" : nil
      )
      client.company_workweeks.create!(
        starts_on_weekday: 0,
        starts_at_minutes: 0,
        timezone: "Pacific/Guam",
        effective_on: Date.new(2026, 1, 1),
        source: client == source_company ? "operator_confirmed" : "legacy_system_default",
        confirmation_status: client == source_company ? "confirmed" : "needs_confirmation",
        confirmed_by: client == source_company ? actor : nil,
        confirmed_at: client == source_company ? Time.current : nil,
        notes: client == source_company ? "Employer confirmed workweek" : nil
      )
    end
  end

  it "copies reviewed live setup while leaving paid history and loan balances behind" do
    source = create(:employee, company: source_company, department: create(:department, company: source_company),
      first_name: "Rosalaine", last_name: "Gumataotao", hire_date: Date.new(1998, 5, 26), pay_rate: 22.50)
    target = create(:employee, company:, department: create(:department, company:),
      first_name: "Rosalaine", last_name: "Gumataotao", ssn_encrypted: source.ssn_digits, hire_date: Date.new(2026, 1, 1), pay_rate: 1)
    EmployeeW4Election.create!(
      company: source_company, employee: source, created_by: actor, effective_on: Date.new(2025, 1, 1),
      filing_status: "single", allowances: 0, additional_withholding: 5, w4_dependent_credit: 0,
      w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0,
      w4_form_version: 2025, source: "staff", reason: "Source election"
    )
    loan_type = DeductionType.create!(company: source_company, name: "Employee loan", category: "post_tax",
      sub_category: "loan", default_amount: 50, active: true)
    EmployeeDeduction.create!(employee: source, deduction_type: loan_type, amount: 50, active: true)
    EmployeeLoan.create!(company: source_company, employee: source, deduction_type: loan_type, name: "Existing loan",
      original_amount: 500, opening_balance: 500, current_balance: 450, balance_as_of: Date.new(2026, 9, 1),
      balance_source: "quickbooks", status: "active")
    create(:pay_period, :committed, company: source_company)

    review = described_class.preview!(company:, source_company:, batch:, effective_on:, actor:)
    expect(review.validation_errors).to be_empty
    expect(review.setup_plan.to_json).not_to include(source.ssn_encrypted)

    expect do
      described_class.apply!(review:, actor:, acknowledgement: described_class::ACKNOWLEDGEMENT)
    end.to change(EmployeeW4Election.where(employee: target), :count).by(1)

    expect(target.reload).to have_attributes(hire_date: Date.new(1998, 5, 26), pay_rate: 22.50)
    expect(company.deduction_types.find_by!(name: "Employee loan")).to have_attributes(default_amount: 50.to_d)
    expect(target.employee_deductions.joins(:deduction_type).find_by!(deduction_types: { name: "Employee loan" })).to have_attributes(amount: 50.to_d)
    expect(target.employee_deductions.joins(:deduction_type).find_by!(deduction_types: { name: "Employee loan" })).not_to be_active
    expect(target.reload.configuration_review_items).to include(include("code" => "loan_balance_not_transferred"))
    expect(company.employee_loans).to be_empty
    expect(company.pay_periods).to be_empty
    expect(company.historical_import_batches).to contain_exactly(batch)
    expect(company.reload.email).to eq("old@example.com")
    expect(company.company_pay_schedules.find_by!(effective_on: effective_on)).to be_confirmed
  end

  it "copies a linked loan field inactive without losing an existing successor ledger" do
    source = create(:employee, company: source_company)
    target = create(:employee, company: company)
    source_field = create(:payroll_field_definition, company: source_company, category: "loan", kind: "deduction", tax_treatment: "post_tax_deduction")
    target_field = create(:payroll_field_definition, company: company, category: "loan", kind: "deduction", tax_treatment: "post_tax_deduction")
    loan = EmployeeLoan.create!(company: source_company, employee: source, name: "Tracked loan", original_amount: 500, current_balance: 450, status: "active")
    source.employee_payroll_fields.create!(payroll_field_definition: source_field, employee_loan: loan, amount: 50, active: true)
    described_class.send(:copy_payroll_fields!, source, target, { source_field => target_field })
    copied = target.employee_payroll_fields.find_by!(payroll_field_definition: target_field)
    expect(copied).not_to be_active
    expect(copied.employee_loan_id).to be_nil
    expect(target.reload.configuration_review_items).to include(include("code" => "loan_balance_not_transferred"))

    target_loan = EmployeeLoan.create!(company: company, employee: target, name: "Verified successor loan", original_amount: 125, current_balance: 125, status: "active")
    copied.update!(employee_loan: target_loan, amount: 25, active: true)
    described_class.send(:copy_payroll_fields!, source, target, { source_field => target_field })
    expect(copied.reload).to have_attributes(employee_loan_id: target_loan.id, amount: 25.to_d, active: true)
    expect(target_loan.reload.current_balance).to eq(125)
  end

  it "refuses a same-name identity conflict before changing successor setup" do
    source = create(:employee, company: source_company, first_name: "Same", last_name: "Name", ssn_encrypted: "900-70-0101", pay_rate: 30)
    target = create(:employee, company: company, first_name: "Same", last_name: "Name", ssn_encrypted: "900-70-0202", pay_rate: 15)
    review = described_class.preview!(company:, source_company:, batch:, effective_on:, actor:)

    expect(review.validation_errors).to include(/Social Security numbers conflict/)
    expect(review.setup_plan.fetch("employee_matches")).to be_empty
    expect(review.validation_errors.join).not_to include(source.ssn_digits, target.ssn_digits)
    expect {
      described_class.apply!(review:, actor:, acknowledgement: described_class::ACKNOWLEDGEMENT)
    }.to raise_error(ArgumentError, /Social Security numbers conflict/)
    expect(target.reload.ssn_digits).to eq("900700202")
    expect(target.pay_rate).to eq(15)
    expect(company.reload.email).to eq("new@example.com")
    expect(company.employee_w4_elections).to be_empty
  end

  it "retains the existing missing-identifier preview behavior" do
    create(:employee, company: source_company, first_name: "Matching", last_name: "Name")
    target = create(:employee, company: company, first_name: "Matching", last_name: "Name")
    target.update_columns(ssn_encrypted: nil)

    review = described_class.preview!(company:, source_company:, batch:, effective_on:, actor:)

    expect(review.validation_errors).to be_empty
    expect(review.setup_plan.fetch("employee_matches").size).to eq(1)
  end

  it "holds copied generic loan defaults inactive while retaining a successor's verified repayment" do
    source = create(:employee, company: source_company, department: create(:department, company: source_company), first_name: "Matched", last_name: "Borrower",
      default_payroll_adjustments: [
        { "label" => "Loan - Installment", "amount" => 250, "treatment" => "post_tax_deduction", "active" => true },
        { "label" => "Health coverage", "amount" => 50, "treatment" => "post_tax_deduction", "active" => true }
      ])
    target = create(:employee, company: company, department: create(:department, company: company), first_name: "Matched", last_name: "Borrower", ssn_encrypted: source.ssn_encrypted)
    field = create(:payroll_field_definition, company: company, name: "Verified repayment", category: "loan", kind: "deduction", tax_treatment: "post_tax_deduction", amount_type: "fixed")
    loan = EmployeeLoan.create!(company: company, employee: target, name: "Verified successor balance", original_amount: 600, current_balance: 600, payment_amount: 250)
    assignment = target.employee_payroll_fields.create!(payroll_field_definition: field, employee_loan: loan, amount: 250, active: true)
    create(:payroll_field_definition, company: source_company, name: "Verified repayment", category: "loan", kind: "deduction", tax_treatment: "pre_tax_deduction", amount_type: "percentage", active: false)
    target_type = DeductionType.create!(company: company, name: "Separate tracked deduction", category: "post_tax", sub_category: "loan", active: true)
    EmployeeLoan.create!(company: company, employee: target, name: "Separate balance", original_amount: 100, current_balance: 100, deduction_type: target_type)
    DeductionType.create!(company: source_company, name: "Separate tracked deduction", category: "pre_tax", sub_category: "loan", active: false)
    create(:tax_table, tax_year: 2026)
    period = create(:pay_period, company: company, pay_date: effective_on)
    review = described_class.preview!(company:, source_company:, batch:, effective_on:, actor:)

    described_class.apply!(review:, actor:, acknowledgement: described_class::ACKNOWLEDGEMENT)

    expect(field.reload).to have_attributes(tax_treatment: "post_tax_deduction", amount_type: "fixed", active: true)
    expect(target_type.reload).to have_attributes(category: "post_tax", active: true)
    expect(target.reload.active_payroll_adjustments.pluck("label")).to eq([ "Health coverage" ])
    expect(target.default_payroll_adjustments.find { |entry| entry["label"] == "Loan - Installment" }).to include("amount" => 250, "active" => false)
    expect(target.configuration_review_items).to include(include("code" => "loan_balance_not_transferred"))
    expect(assignment.reload).to have_attributes(employee_loan_id: loan.id, amount: 250.to_d, active: true)
    expect(loan.reload.current_balance).to eq(600)
    expect(loan.loan_transactions).to be_empty
    expect(source.reload.active_payroll_adjustments.pluck("label")).to include("Loan - Installment")

    item = create(:payroll_item, company: company, employee: target, pay_period: period, hours_worked: 80)
    item.sync_default_payroll_adjustments!(target)
    PayrollCalculator.for(target, item).calculate
    item.save!
    expect(item.post_tax_payroll_adjustments_total).to eq(50)
    expect(item.payroll_item_deductions.select { |entry| entry.employee_loan_id == loan.id }.sum(&:amount)).to eq(250)
  end

  it "blocks a transfer when an active employee cannot be matched" do
    create(:employee, company: source_company, first_name: "Source", last_name: "Only")
    create(:employee, company:, first_name: "Successor", last_name: "Only")

    review = described_class.preview!(company:, source_company:, batch:, effective_on:, actor:)

    expect(review.validation_errors).to include(/no active source employee match/)
    expect do
      described_class.apply!(review:, actor:, acknowledgement: described_class::ACKNOWLEDGEMENT)
    end.to raise_error(ArgumentError, /no active source employee match/)
  end

  it "rejects a stale preview after successor employee setup changes" do
    source = create(:employee, company: source_company, first_name: "Eithen", last_name: "Hadley", pay_rate: 30)
    target = create(:employee, company:, first_name: "Eithen", last_name: "Hadley", pay_rate: 15, ssn_encrypted: source.ssn_encrypted)
    review = described_class.preview!(company:, source_company:, batch:, effective_on:, actor:)

    target.employee_wage_rates.create!(label: "Corrected rate", rate: 25, active: true, is_primary: false)

    expect do
      described_class.apply!(review:, actor:, acknowledgement: described_class::ACKNOWLEDGEMENT)
    end.to raise_error(ArgumentError, /Source or successor setup changed/)
    expect(target.reload.pay_rate).to eq(15.to_d)
  end
end
