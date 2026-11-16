# frozen_string_literal: true

require "rails_helper"
require "caxlsx"

RSpec.describe "Setting up an installment loan from MoSa import review", type: :request do
  let!(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:staff) { create(:user, company: company, role: "accountant") }
  let!(:emma) { create(:employee, company: company, first_name: "Emma", last_name: "Mercer", pay_rate: 12) }
  let!(:run) { create(:pay_period, company: company) }
  let(:url) { "/api/v1/admin/pay_periods/#{run.id}" }
  let(:objects) { {} }
  let(:storage) do
    entries = objects
    Object.new.tap do |store|
      store.define_singleton_method(:upload) { |key, data, **| entries[key] = data }
      store.define_singleton_method(:download_with_limit) { |key, **| entries.fetch(key) }
      store.define_singleton_method(:delete) { |key| entries.delete(key) }
    end
  end

  before do
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: run.pay_date.year)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
    stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
    allow(R2StorageService).to receive(:new).and_return(storage)
    CompanyWorkweek.create!(company: company, starts_on_weekday: run.start_date.wday, starts_at_minutes: 0,
      timezone: "Pacific/Guam", effective_on: run.start_date, source: "operator_confirmed", confirmation_status: "confirmed",
      confirmed_by: staff, confirmed_at: Time.current, notes: "Synthetic confirmed workweek")
  end

  # MoSa's own workbook: by default a new $600 installment loan, $50 a
  # payroll. Built once so a second upload is byte-for-byte the same file.
  let(:installment_row) { [ 0, 600, 50, 550 ] }
  let(:workbook_bytes) do
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: PayrollImport::LoanTipExcelParser::INSTALLMENT_SHEET) do |sheet|
      sheet.add_row([ "INSTALLMENT LOANS" ])
      sheet.add_row([ "PAY PERIOD ENDING", nil, run.end_date ])
      sheet.add_row([ "PAY DAY", nil, run.pay_date ])
      sheet.add_row([ nil, "Nickname", "Last Name", "First Name", "Dept", "Beginning Balance", "New Loan", "Payment", "Estimated Ending" ])
      sheet.add_row([ 1, nil, "Mercer", "Emma", "Joint", *installment_row ])
    end
    package.to_stream.read
  end
  let(:pdf_bytes) do
    File.binread(build_revel_pdf([ { name: "Mercer, Elena", regular_hours: 40, regular_pay: 480 } ],
      period_start: run.start_date, period_end: run.end_date))
  end

  def preview!
    post "#{url}/preview_import", params: {
      pdf_file: portal_upload("revel.pdf", pdf_bytes, "application/pdf"),
      excel_file: portal_upload("tips-loans.xlsx", workbook_bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
      tips_paid_out_from_tips: true
    }
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  def emma_row(data) = data.dig("preview", "matched").find { |row| row["employee_id"] == emma.id }
  def emma_source(data) = data.dig("preview", "source_rows").find { |row| row["employee_id"] == emma.id }

  def set_up!(data, **fields)
    post "#{url}/import_installment_loan", params: { import_id: data["import_id"], employee_id: emma.id, **fields }, as: :json
  end

  it "creates the loan from the workbook, audits it, never duplicates it, and the review reconciles after matching again" do
    first = preview!
    expect(first["loan_setup"]).to eq("allowed" => true, "reason" => nil)
    expect(emma_row(first)["installment_loan_setup"]).to include("action" => "create", "starting_balance" => "600.0",
      "payment_amount" => "50.0", "first_deduction_date" => run.pay_date.iso8601)
    expect(emma_source(first)["errors"].map { |error| error["code"] }).to eq([ "loan_reconciliation_required" ])

    set_up!(first, name: "Emma advance", starting_balance: "600", payment_amount: "50", first_deduction_date: run.pay_date.iso8601)
    expect(response).to have_http_status(:created), response.body
    loan = EmployeeLoan.find(response.parsed_body["loan_id"])
    expect(loan).to have_attributes(employee_id: emma.id, name: "Emma advance", tracking_mode: "balance_tracked", status: "active",
      current_balance: 600, payment_amount: 50, first_deduction_date: run.pay_date, balance_as_of: run.pay_date,
      balance_source: "new_loan", created_by_id: staff.id)
    expect(loan.repayment_schedule_active_on?(run.pay_date)).to be(true)
    audit = AuditLog.find_by!(action: "employee_loans#create", record_id: loan.id)
    expect(audit).to have_attributes(user_id: staff.id, company_id: company.id, record_type: "employee_loans")
    expect(audit.metadata).to include("source" => "payroll_import_review", "pay_period_id" => run.id, "import_id" => first["import_id"])
    expect(AuditLog.where(action: "payroll_imports#installment_loan")).to be_empty

    # A second click, or another window, gets the same loan back.
    set_up!(first, name: "Emma advance", starting_balance: "600", payment_amount: "50", first_deduction_date: run.pay_date.iso8601)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to eq("loan_id" => loan.id, "already_set_up" => true)
    expect(emma.employee_loans.count).to eq(1)

    post "#{url}/rematch_import", params: { reason: "Matched again after Elena Mercer's installment loan was set up" }
    expect(response).to have_http_status(:ok), response.body
    second = response.parsed_body
    expect(second.dig("source_package", "package_revision")).to eq(2)
    expect(second.dig("source_package", "supersession_reason")).to eq("Matched again after Elena Mercer's installment loan was set up")
    expect(emma_source(second)["errors"]).to eq([])
    expect(emma_row(second)["installment_loan_setup"]).to be_nil
    expect(emma_row(second)["loan_reconciliation_matches"]).to contain_exactly(include("employee_loan_id" => loan.id, "amount" => "50.0"))

    # The same files again return the reconciled review, not another version or loan.
    preview_again = preview!
    expect(preview_again["import_id"]).to eq(second["import_id"])
    expect(emma.employee_loans.count).to eq(1)

    rows = second.dig("preview", "source_rows").map { |row| { id: row["id"], disposition: "included" } }
    post "#{url}/apply_import", params: { import_id: second["import_id"], rows: rows }, as: :json
    expect(response).to have_http_status(:ok), response.body
    item = run.payroll_items.find_by!(employee: emma)
    expect(item.payroll_item_deductions.where(employee_loan_id: loan.id).sum(:amount)).to eq(50)
    expect(item.loan_deduction).to eq(0)
  end

  it "offers to resume a paused loan and resumes it instead of adding another" do
    type = DeductionType.create!(company: company, name: "Emma loan", category: "post_tax", sub_category: "loan", active: true)
    loan = EmployeeLoan.create!(company: company, employee: emma, deduction_type: type, name: "Emma loan", original_amount: 600,
      opening_balance: 600, current_balance: 600, balance_as_of: run.start_date, balance_source: "new_loan",
      payment_amount: 50, first_deduction_date: run.pay_date)
    emma.employee_deductions.create!(deduction_type: type, amount: 50, is_percentage: false, active: true)
    loan.suspend!

    data = preview!
    expect(emma_row(data)["installment_loan_setup"]).to include("action" => "resume", "employee_loan_id" => loan.id, "name" => "Emma loan")

    set_up!(data)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to eq("loan_id" => loan.id, "already_set_up" => false)
    expect(loan.reload).to be_active
    expect(emma.employee_loans.count).to eq(1)
    expect(AuditLog.find_by!(action: "employee_loans#reactivate", record_id: loan.id).metadata).to include("source" => "payroll_import_review")
  end

  it "shows the reason instead of the action to staff who can't set up loans, and refuses the request" do
    allow(TestWorkspaceAccessPolicy).to receive(:allowed?).and_call_original
    allow(TestWorkspaceAccessPolicy).to receive(:allowed?)
      .with(hash_including(controller_path: "api/v1/admin/employee_loans")).and_return(false)

    data = preview!
    expect(data["loan_setup"]).to include("allowed" => false, "reason" => a_string_including("Ask an admin to set up the loan in Employee Loans"))

    set_up!(data, starting_balance: "600", payment_amount: "50")
    expect(response).to have_http_status(:forbidden)
    expect(emma.employee_loans).to be_empty
  end

  it "refuses an inactive worker and a stale review without creating a loan" do
    data = preview!
    emma.update_columns(status: "inactive")
    set_up!(data)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Elena Mercer isn't active. Reactivate them before setting up the loan.")

    emma.update_columns(status: "active")
    post "#{url}/import_installment_loan", params: { import_id: data["import_id"] + 1, employee_id: emma.id }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(emma.employee_loans).to be_empty
  end

  it "only deducts first on this payroll's pay date" do
    data = preview!
    set_up!(data, starting_balance: "600", payment_amount: "50", first_deduction_date: (run.pay_date - 14).iso8601)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("The first deduction is this payroll's pay date, #{run.pay_date.strftime('%-m/%-d/%Y')}.")
    expect(EmployeeLoan.count).to eq(0)
  end

  context "with an existing balance and a new advance in the workbook" do
    let(:installment_row) { [ 200, 100, 50, 250 ] }

    it "records the beginning balance and the advance as separate ledger entries, and the review reconciles" do
      data = preview!
      expect(emma_row(data)["installment_loan_setup"]).to include("starting_balance" => "300.0", "beginning_balance" => "200.0", "new_amount" => "100.0")
      set_up!(data)
      expect(response).to have_http_status(:created), response.body
      loan = EmployeeLoan.find(response.parsed_body["loan_id"])
      expect(loan).to have_attributes(opening_balance: 200, current_balance: 300, balance_source: "other_verified", balance_as_of: run.pay_date)
      expect(loan.loan_transactions.order(:id).map { |entry| [ entry.transaction_type, entry.amount.to_d ] }).to eq([ [ "addition", 200 ], [ "addition", 100 ] ])
      expect(AuditLog.find_by!(action: "employee_loans#create", record_id: loan.id).metadata).to include("current_balance" => "300.0")

      post "#{url}/rematch_import"
      expect(emma_source(response.parsed_body)["errors"]).to eq([])
    end

    it "refuses a stale offer once the installment was paid off, instead of adding a second debt" do
      data = preview!
      type = DeductionType.create!(company: company, name: "Old loan", category: "post_tax", sub_category: "loan", active: true)
      EmployeeLoan.create!(company: company, employee: emma, deduction_type: type, name: "Old loan", original_amount: 50, opening_balance: 50,
        current_balance: 0, balance_as_of: run.start_date - 30, balance_source: "new_loan", payment_amount: 50, status: "paid_off", paid_off_date: run.start_date - 10)
      set_up!(data)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("was paid off in Employee Loans")
      expect(emma.employee_loans.count).to eq(1)

      post "#{url}/rematch_import"
      second = response.parsed_body
      expect(emma_row(second)["installment_loan_setup"]).to be_nil
      expect(emma_source(second)["errors"].sole["message"]).to include("Old loan was paid off on")
    end
  end

  it "rejects a payment larger than the starting balance and leaves no partial loan" do
    data = preview!
    set_up!(data, starting_balance: "40", payment_amount: "50")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Payment per payroll can't be more than the starting balance")
    expect(EmployeeLoan.count).to eq(0)
    expect(DeductionType.where(sub_category: "loan")).to be_empty
  end
end
