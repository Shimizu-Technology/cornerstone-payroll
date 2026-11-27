# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Adding a removed worker back restores the import's amounts", type: :request do
  let!(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:staff) { create(:user, company: company, role: "admin") }
  let!(:avery) { create(:employee, company: company, first_name: "Avery", last_name: "Example", pay_rate: 20) }
  # Not in Revel; the workbook has a one-time loan and tips for him.
  let!(:jordan) { create(:employee, company: company, first_name: "Jordan", last_name: "Workbook", pay_rate: 35) }
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
    [ Api::V1::Admin::PayrollImportsController, Api::V1::Admin::PayrollItemsController,
      Api::V1::Admin::PayPeriodExcludedEmployeesController, Api::V1::Admin::PayPeriodsController ].each do |controller|
      stub_portal_user(controller, staff, company)
    end
    allow(R2StorageService).to receive(:new).and_return(storage)
    CompanyWorkweek.create!(company: company, starts_on_weekday: run.start_date.wday, starts_at_minutes: 0,
      timezone: "Pacific/Guam", effective_on: run.start_date, source: "operator_confirmed", confirmation_status: "confirmed",
      confirmed_by: staff, confirmed_at: Time.current, notes: "Synthetic confirmed workweek")
  end

  def workbook(loan: 150.00, tips: 20)
    file = Tempfile.new([ "tips-and-loans", ".xlsx" ])
    package = Axlsx::Package.new
    [ [ "TIPS - BOH", "TIPS - BOH (KITCHEN)", tips ], [ "LOANS (NO INSTALLMENTS)", "LOANS (Do NOT Enter Any Amounts with Installment Payments)", loan ] ].each do |name, title, amount|
      package.workbook.add_worksheet(name: name) do |sheet|
        sheet.add_row([ title ])
        sheet.add_row([ "PAY PERIOD ENDING", nil, run.end_date ])
        sheet.add_row([ "PAY DAY", nil, run.pay_date ])
        sheet.add_row([ nil, "Nickname", "Last Name", "First Name", "Dept", "ENTER AMOUNTS HERE" ])
        sheet.add_row([ 1, nil, "Workbook", "Jordan", "Kitchen", amount ])
      end
    end
    package.serialize(file.path)
    File.binread(file.path)
  ensure
    file&.unlink
  end

  def preview!(avery_hours: 40, replaces: nil, loan: 150.00)
    pdf = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: avery_hours, regular_pay: 400 } ],
      period_start: run.start_date, period_end: run.end_date))
    post "#{url}/preview_import", params: {
      pdf_file: portal_upload("revel.pdf", pdf, "application/pdf"),
      excel_file: portal_upload("tips-and-loans.xlsx", workbook(loan: loan), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
      tips_paid_out_from_tips: false,
      **(replaces ? { supersedes_package_id: replaces, supersession_reason: "Corrected Revel hours" } : {})
    }
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  def apply!(data, **params)
    rows = data.dig("preview", "source_rows").map { |row| { id: row["id"], disposition: "included" } }
    post "#{url}/apply_import", params: { import_id: data["import_id"], rows: rows, **params }, as: :json
    expect(response).to have_http_status(:ok), response.body
  end

  def jordan_item = run.payroll_items.find_by(employee: jordan)

  def remove_jordan!
    delete "#{url}/payroll_items/#{jordan_item.id}"
    expect(response).to have_http_status(:no_content), response.body
    expect(jordan_item).to be_nil
  end

  def add_back_jordan!
    delete "#{url}/excluded_employees/#{jordan.id}", as: :json
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.fetch("add_back")
  end

  def calculate_jordan!(hours: 40)
    post "#{url}/run_payroll", params: { employee_ids: [ avery.id, jordan.id ],
      hours: { jordan.id.to_s => { regular: hours, overtime: 0 } } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors")).to be_empty
    jordan_item.reload
  end

  def current_package_id = PayrollIntakeSession.where(pay_period: run).order(:package_revision).last.package_id

  def kitchen_loan!(amount: 100, scheduled: true)
    type = DeductionType.create!(company: company, name: "Kitchen loan", category: "post_tax", sub_category: "loan", active: true)
    loan = EmployeeLoan.create!(company: company, employee: jordan, deduction_type: type, name: "Kitchen loan",
      tracking_mode: "recurring_no_balance", payment_amount: amount, first_deduction_date: run.pay_date)
    jordan.employee_deductions.create!(deduction_type: type, amount: amount, is_percentage: false, active: true) if scheduled
    loan
  end

  # The loan the row ends up deducting, plus any loan the notice asks staff
  # to enter by hand, never exceeds what the workbook asked for.
  def expect_no_loan_overdeduction!(add_back, item)
    by_hand = add_back["not_restored"].select { |row| row["kind"].in?(%w[loan scheduled_loan]) && row["enter_by_hand"] }
    # loan_payment is the paycheck's whole loan: scheduled plus the direct amount.
    deducted = item ? item.loan_payment.to_d : 0.to_d
    expect(deducted + by_hand.sum { |row| row["amount"].to_d }).to be <= 150.00.to_d
  end

  def import_and_remove!
    apply!(preview!)
    expect(jordan_item).to have_attributes(requested_loan_deduction: 150.00.to_d, reported_tips: 20.to_d, import_source: "mosa_revel")
    remove_jordan!
  end

  it "brings back the loan and tips, leaves hours for staff, and deducts the loan once hours are calculated" do
    import_and_remove!

    add_back = add_back_jordan!

    expect(add_back).to include("employee_name" => "Jordan Workbook", "not_restored" => [])
    expect(add_back["restored"]).to contain_exactly(
      { "key" => "loan", "kind" => "loan", "label" => "Loan", "amount" => "150.0" },
      { "key" => "tips", "kind" => "tips", "label" => "Tips", "amount" => "20.0" }
    )
    expect(jordan_item).to have_attributes(hours_worked: 0, requested_loan_deduction: 150.00.to_d, reported_tips: 20.to_d,
      tips_paid_out: 0, import_source: "mosa_revel")
    expect(jordan_item.deduction_review_warnings).to include("No Revel hours — enter hours from MoSa's email before calculating.")
    expect(run.reload).to be_draft
    audit = AuditLog.where(action: "pay_period_excluded_employees#destroy").sole
    expect(audit.metadata).to include("employee_id" => jordan.id, "import_id" => PayrollImportRecord.where(pay_period: run).sole.id,
      "restored_import_amounts" => add_back["restored"], "not_restored_import_amounts" => [])

    item = calculate_jordan!
    expect_no_loan_overdeduction!(add_back, item)
    expect(item.gross_pay).to eq(1420.to_d)
    expect(item.loan_deduction).to eq(150.00.to_d)
    taxes = item.withholding_tax + item.social_security_tax + item.medicare_tax + item.additional_medicare_tax.to_d
    expect(item.net_pay).to eq(item.gross_pay - taxes - 150.00.to_d - item.retirement_payment.to_d - item.insurance_payment.to_d)
    expect(item.total_deductions).to be >= 150.00.to_d
  end

  it "doesn't double the loan when the worker is removed and added back again" do
    import_and_remove!
    add_back_jordan!
    remove_jordan!
    add_back = add_back_jordan!

    expect(add_back["restored"].map { |row| row["amount"] }).to contain_exactly("150.0", "20.0")
    expect(jordan_item).to have_attributes(requested_loan_deduction: 150.00.to_d, reported_tips: 20.to_d)
    expect(calculate_jordan!.loan_deduction).to eq(150.00.to_d)
    expect(AuditLog.where(action: "pay_period_excluded_employees#destroy").count).to eq(2)
  end

  it "doesn't double the loan when the import is applied again after the add-back" do
    import_and_remove!
    add_back_jordan!
    calculate_jordan!

    apply!(preview!(avery_hours: 39, replaces: current_package_id), confirm_hours_overwrite: true)

    item = jordan_item.reload
    expect(item).to have_attributes(requested_loan_deduction: 150.00.to_d, reported_tips: 20.to_d, hours_worked: 40)
    expect(item.loan_deduction).to eq(150.00.to_d)
  end

  it "restores nothing from an import that newer files replaced, and lists what to enter" do
    import_and_remove!
    preview!(avery_hours: 38, replaces: current_package_id)

    add_back = add_back_jordan!

    expect(add_back["restored"]).to be_empty
    expect(add_back["not_restored"]).to contain_exactly(
      include("kind" => "loan", "amount" => "150.0", "enter_by_hand" => true,
        "reason" => "The import was replaced by newer files. Apply the current import review, or enter it by hand. Enter it under Hours → Tips & Deductions."),
      include("kind" => "tips", "amount" => "20.0", "enter_by_hand" => true)
    )
    expect(jordan_item).to be_nil
    expect_no_loan_overdeduction!(add_back, calculate_jordan!)
    expect(run.pay_period_excluded_employees).to be_empty
    expect(AuditLog.where(action: "pay_period_excluded_employees#destroy").sole.metadata["not_restored_import_amounts"].size).to eq(2)
  end

  it "sends a loan Employee Loans now schedules to Employee Loans, never to hand entry" do
    import_and_remove!
    kitchen_loan!(amount: 100)

    add_back = add_back_jordan!

    expect(add_back["restored"]).to contain_exactly(include("kind" => "tips", "amount" => "20.0"))
    expect(add_back["not_restored"]).to contain_exactly(include("kind" => "loan", "amount" => "150.0", "enter_by_hand" => false,
      "reason" => "Kitchen loan is $100.00 for this payday, but the workbook says $150.00. Update the schedule in Cornerstone or correct the workbook. " \
        "Employee Loans will deduct $100.00 this payday (Kitchen loan); the workbook says $150.00. Check it in Employee Loans. Don't enter the workbook loan by hand."))
    expect(jordan_item).to have_attributes(requested_loan_deduction: 0, reported_tips: 20.to_d)
    expect(jordan_item.custom_columns_data["mosa_missing_revel_hours"]).to be(false)
    item = calculate_jordan!
    expect(item.loan_payment).to eq(100.to_d)
    expect_no_loan_overdeduction!(add_back, item)
  end

  it "sends a paused loan to Employee Loans and says it deducts nothing" do
    import_and_remove!
    kitchen_loan!(amount: 100).update!(status: "suspended")

    add_back = add_back_jordan!

    # Nothing will be deducted, so staff resume the loan or enter a one-time amount; never both.
    expect(add_back["not_restored"]).to contain_exactly(include("kind" => "loan", "enter_by_hand" => true,
      "reason" => a_string_starting_with("Kitchen loan is paused").and(ending_with(
        "Employee Loans will deduct nothing this payday; the workbook says $150.00. Resume the loan in Employee Loans, " \
        "or, if the workbook amount really is one-time this period, enter it under Hours → Tips & Deductions."))))
    expect_no_loan_overdeduction!(add_back, calculate_jordan!)
  end

  it "doesn't ask for the loan by hand from a replaced import when Employee Loans now deducts one" do
    import_and_remove!
    preview!(avery_hours: 38, replaces: current_package_id)
    kitchen_loan!(amount: 100)

    add_back = add_back_jordan!

    expect(add_back["not_restored"]).to include(include("kind" => "loan", "enter_by_hand" => false,
      "reason" => a_string_including("Employee Loans will deduct $100.00 this payday (Kitchen loan)")))
    expect_no_loan_overdeduction!(add_back, calculate_jordan!)
  end

  it "clears an earlier Not paid this period answer, so approval waits for the added-back worker's hours" do
    # Jordan is usually paid: paid in three of the last four committed runs,
    # kept in the prior tax year so this year's FICA history isn't involved.
    4.times do |index|
      offset = 1.year + (index * 14).days
      past = create(:pay_period, company: company, start_date: run.start_date - offset, end_date: run.end_date - offset,
        pay_date: run.pay_date - offset)
      create(:payroll_item, pay_period: past, employee: jordan, gross_pay: 200) if index < 3
      # History only; these runs are never recalculated here.
      past.update_columns(status: "committed", committed_at: Time.current)
    end
    # Before the files arrived, staff answered Not paid this period.
    resolution = PayrollEntryResolution.create!(pay_period: run, employee: jordan, note: "No shifts yet")
    import_and_remove!

    add_back_jordan!

    expect(PayrollEntryResolution.exists?(resolution.id)).to be(false)
    audit = AuditLog.where(action: "pay_period_excluded_employees#destroy").sole
    expect(audit.metadata["cleared_entry_resolutions"]).to eq([ { "payroll_standing_change_id" => nil, "note" => "No shifts yet" } ])
    entries = PayrollExpectedEntries.new(run.reload).payload
    expect(entries[:missing_regulars]).to include(include(employee_id: jordan.id, resolved: false, awaiting_hours: true))
    expect(entries[:outstanding]).to include(jordan.full_name)
    calculate_jordan!(hours: 0)
    expect(PayrollExpectedEntries.new(run.reload).payload[:outstanding]).to include(jordan.full_name)
  end

  it "returns the recorded add-back when the request is repeated, and keeps it in Expected entries until hours are in" do
    import_and_remove!
    first = add_back_jordan!
    expect(add_back_jordan!).to eq(first)
    expect(AuditLog.where(action: "pay_period_excluded_employees#destroy").count).to eq(1)

    added_back = PayrollExpectedEntries.new(run.reload).payload[:added_back]
    expect(added_back).to contain_exactly(include(employee_id: jordan.id, hours_entered: false, restored: first["restored"]))
    calculate_jordan!
    expect(PayrollExpectedEntries.new(run.reload).payload[:added_back]).to be_empty
  end

  it "keeps a not-restored amount listed after hours are in, and drops it once a newer import is applied" do
    import_and_remove!
    kitchen_loan!(amount: 100)
    add_back_jordan!
    calculate_jordan!

    expect(PayrollExpectedEntries.new(run.reload).payload[:added_back])
      .to contain_exactly(include(employee_id: jordan.id, hours_entered: true, not_restored: [ include("kind" => "loan") ]))
    # The corrected workbook matches the new Employee Loans schedule.
    apply!(preview!(avery_hours: 39, replaces: current_package_id, loan: 100), confirm_hours_overwrite: true)
    expect(PayrollExpectedEntries.new(run.reload).payload[:added_back]).to be_empty
    expect(jordan_item.reload.loan_payment).to eq(100.to_d)
  end

  it "says nothing came back for a worker the import didn't include" do
    apply!(preview!)
    other = create(:employee, company: company, first_name: "Casey", last_name: "Manual")
    PayPeriodExcludedEmployee.create!(pay_period: run, employee: other, reason: "Removed from pay period", excluded_by: staff)

    delete "#{url}/excluded_employees/#{other.id}", as: :json

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body["add_back"]).to include("employee_name" => "Casey Manual", "restored" => [], "not_restored" => [])
    expect(run.payroll_items.find_by(employee: other)).to be_nil
    expect(AuditLog.where(action: "pay_period_excluded_employees#destroy").sole.metadata).not_to have_key("restored_import_amounts")
  end
end
