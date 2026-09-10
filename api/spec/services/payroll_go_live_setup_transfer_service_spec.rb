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
      first_name: "Rosalaine", last_name: "Gumataotao", hire_date: Date.new(2026, 1, 1), pay_rate: 1)
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
    described_class.copy_payroll_fields!(source, target, { source_field => target_field })
    copied = target.employee_payroll_fields.find_by!(payroll_field_definition: target_field)
    expect(copied).not_to be_active
    expect(copied.employee_loan_id).to be_nil
    expect(target.reload.configuration_review_items).to include(include("code" => "loan_balance_not_transferred"))

    target_loan = EmployeeLoan.create!(company: company, employee: target, name: "Verified successor loan", original_amount: 125, current_balance: 125, status: "active")
    copied.update!(employee_loan: target_loan, amount: 25, active: true)
    described_class.copy_payroll_fields!(source, target, { source_field => target_field })
    expect(copied.reload).to have_attributes(employee_loan_id: target_loan.id, amount: 25.to_d, active: true)
    expect(target_loan.reload.current_balance).to eq(125)
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
    create(:employee, company: source_company, first_name: "Eithen", last_name: "Hadley", pay_rate: 30)
    target = create(:employee, company:, first_name: "Eithen", last_name: "Hadley", pay_rate: 15)
    review = described_class.preview!(company:, source_company:, batch:, effective_on:, actor:)

    target.employee_wage_rates.create!(label: "Corrected rate", rate: 25, active: true, is_primary: false)

    expect do
      described_class.apply!(review:, actor:, acknowledgement: described_class::ACKNOWLEDGEMENT)
    end.to raise_error(ArgumentError, /Source or successor setup changed/)
    expect(target.reload.pay_rate).to eq(15.to_d)
  end
end
