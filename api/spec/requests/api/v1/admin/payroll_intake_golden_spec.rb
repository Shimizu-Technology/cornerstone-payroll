# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("spec/fixtures/files/payroll_intake_golden/build_workbooks")

RSpec.describe "Payroll intake golden files", type: :request do
  PDF_MIME = "application/pdf"
  XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  let(:company) do
    create(:company, id: IntakeGoldenWorkbooks::COMPANY_ID, name: "Synthetic Fixture Restaurant",
      payroll_intake_source_types: %w[mosa_revel spike_email])
  end
  let(:staff) { create(:user, company: company, role: "admin") }
  let(:run) do
    create(:pay_period, company: company, start_date: IntakeGoldenWorkbooks::START_DATE,
      end_date: IntakeGoldenWorkbooks::END_DATE, pay_date: IntakeGoldenWorkbooks::PAY_DATE)
  end
  let!(:worker) { create_worker(IntakeGoldenWorkbooks::WORKER) }
  let(:workweek_start) { run.start_date.wday }
  let(:objects) { {} }
  let(:storage) do
    entries = objects
    Object.new.tap do |store|
      store.define_singleton_method(:upload) { |key, data, **| entries[key] = data.respond_to?(:read) ? File.binread(data.path) : data }
      store.define_singleton_method(:download_with_limit) { |key, max_bytes:| entries.fetch(key).byteslice(0, max_bytes) }
      store.define_singleton_method(:delete) { |key| entries.delete(key) }
    end
  end

  before do
    stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
    stub_portal_user(Api::V1::Admin::PayrollIntakeImportsController, staff, company)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(ClientDocumentScanner).to receive(:adapter).and_return(ClientDocumentScanner::Noop.new)
    CompanyWorkweek.create!(company: company, starts_on_weekday: workweek_start, starts_at_minutes: 0,
      timezone: "Pacific/Guam", effective_on: run.start_date - 7, source: "operator_confirmed",
      confirmation_status: "confirmed", confirmed_by: staff, confirmed_at: Time.current, notes: "Synthetic workweek")
  end

  def create_worker(identity, **attributes)
    id, name = identity
    first_name, last_name = name.split
    create(:employee, company: company, id: id, first_name: first_name, last_name: last_name, pay_rate: 15.50, **attributes)
  end

  def revel_row_for(employee, regular:, overtime: 0, **extra)
    # Source pay intentionally disagrees with the stored rate.
    { name: "#{employee.last_name}, #{employee.first_name}", regular_hours: regular,
      overtime_hours: overtime, regular_pay: 711.11, overtime_pay: overtime * 30, **extra }
  end

  def pdf_upload(*rows, reported_total_hours: nil, filename: "revel.pdf", report_period: [ run.start_date, run.end_date ])
    path = build_revel_pdf(rows, period_start: report_period.first, period_end: report_period.last, reported_total_hours: reported_total_hours)
    portal_upload(filename, File.binread(path), PDF_MIME)
  end

  def workbook_upload(name)
    portal_upload("#{name}.xlsx", File.binread(File.join(IntakeGoldenWorkbooks::DIRECTORY, "#{name}.xlsx")), XLSX_MIME)
  end

  def preview(pdf: nil, workbook: nil, **options)
    post "/api/v1/admin/pay_periods/#{run.id}/preview_import", params: {
      pdf_file: pdf, excel_file: workbook, **options
    }.compact
    response.parsed_body
  end

  def apply_import(data, **options)
    post "/api/v1/admin/pay_periods/#{run.id}/apply_import", params: { import_id: data.fetch("import_id"), **options }, as: :json
  end

  def set_up_payroll_tax
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: run.pay_date.year)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
  end

  def decimal_fields(record, *keys)
    record.merge(record.slice(*keys).transform_values { |value| value&.to_d&.to_s("F") })
  end

  def saved_payroll(item = run.payroll_items.find_by!(employee: worker))
    money = %w[reported_tips tips_paid_out loan_deduction bonus]
    item.attributes.slice("hours_worked", "overtime_hours").transform_values(&:to_f).merge(
      decimal_fields(item.attributes.slice(*money), *money)
    )
  end

  def expect_apply_blocked(data, **options)
    apply_import(data, **options)
    expect(response).to have_http_status(:unprocessable_entity), response.body
    response.parsed_body.fetch("error")
  end

  def expect_golden(name, actual)
    json = File.read(File.join(IntakeGoldenWorkbooks::DIRECTORY, "#{name}.json"))
    display_name = PayrollIntake::Adapters::MosaRevel::SOURCE_LABEL.split.first
    expected = JSON.parse(json.gsub("{{adapter_display_name}}", display_name))
    expect(actual).to eq(expected)
  end

  def mosa_preview(data)
    expect(response).to have_http_status(:ok), response.body
    review = data.fetch("preview")
    retained = PayrollImportRecord.find(data.fetch("import_id")).payroll_intake_session
    normalized = retained.rows.index_by(&:id)
    matched = review.fetch("matched").index_by { |row| row.fetch("source_row_id") }

    review.slice("can_apply", "pdf_count", "excel_count", "source_warnings", "unmatched_pdf_names", "unmatched_excel_names").merge(
      "source_roles" => data.dig("source_package", "documents").pluck("source_role"),
      "complete" => data.dig("source_package", "complete"),
      "totals" => decimal_fields(retained.totals, "total_reported_tips"),
      "rows" => review.fetch("source_rows").map do |source_row|
        id = source_row.fetch("id")
        row = normalized.fetch(id)
        inputs = matched[id]&.slice(
          "total_hours", "workbook_only", "pay_rate", "tips_boh", "tips_foh", "tip_pool",
          "loan_deduction", "loan_reconciliation_errors", "loan_reconciliation_warnings",
          "bonus", "period_pay", "payroll_components", "hand_edited_hours"
        )
        source_row.slice("source_employee_name", "employee_id", "employee_name", "row_kind", "errors", "warnings").merge(
          "status" => row.status,
          "regular_hours" => row.regular_hours.to_f,
          "overtime_hours" => row.overtime_hours.to_f,
          "reported_tips" => row.reported_tips.to_s("F"),
          "tips_paid_out" => row.tips_paid_out.to_s("F"),
          "payroll_inputs" => inputs && decimal_fields(inputs, "pay_rate", "tips_boh", "tips_foh", "loan_deduction", "bonus", "period_pay")
        )
      end
    )
  end

  it "imports a normal v2 period with both tip pools and a typed reimbursement" do
    set_up_payroll_tax
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 75.25, overtime: 1.5)), workbook: workbook_upload("normal"))
    snapshot = mosa_preview(data)
    apply_import(data)
    expect(response).to have_http_status(:ok), response.body
    item = run.payroll_items.find_by!(employee: worker)
    earning = item.payroll_item_earnings.find_by!(label: "Fixture supplies")
    expect(item.payroll_item_field_entries.sole).to have_attributes(tax_treatment: "non_taxable_addition", source: "import")
    expect(item.net_pay + item.total_deductions - item.gross_pay).to eq(BigDecimal("12.34"))
    snapshot["saved_payroll"] = saved_payroll(item).merge(
      "reimbursement" => decimal_fields(earning.attributes.slice("label", "category", "amount"), "amount")
    )
    expect_golden("normal", snapshot)
  end

  it "keeps the reported overtime split visible while blocking a Revel row with unaccounted hours" do
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 80, overtime: 31.75, total_hours: 125), reported_total_hours: 999),
      workbook: workbook_upload("overtime_heavy"))
    snapshot = mosa_preview(data)
    snapshot["apply_error"] = expect_apply_blocked(data)
    expect(run.payroll_items).to be_empty
    expect_golden("overtime_heavy", snapshot)
  end

  it "blocks applying a Revel row with double-time hours" do
    pdf = pdf_upload(revel_row_for(worker, regular: 72, doubletime_hours: BigDecimal("3.00")))
    data = preview(pdf: pdf, workbook: workbook_upload("overtime_heavy"))
    snapshot = mosa_preview(data)
    snapshot["doubletime_hours"] = data.fetch("preview").fetch("matched").sole.fetch("doubletime_hours")
    snapshot["apply_error"] = expect_apply_blocked(data)
    expect(run.payroll_items).to be_empty
    expect_golden("doubletime", snapshot)
  end

  it "blocks a PDF row when double-time drifts outside its column and lets staff apply the other row" do
    set_up_payroll_tax
    other_worker = create_worker(IntakeGoldenWorkbooks::NEW_HIRE)
    affected_row = revel_row_for(worker, regular: 40, total_hours: 42.25)
    path = build_revel_pdf([ affected_row, revel_row_for(other_worker, regular: 39) ],
      period_start: run.start_date, period_end: run.end_date) do |row|
      next revel_row(**row) unless row[:name] == affected_row[:name]

      # PDF::Reader places 2.25 after column 159, in the regular pay field.
      fields = %w[- - - 40.00 0.00 - 2.25 - - 42.25 600.00 -]
      row.fetch(:name).ljust(40) + fields.map { |value| value.rjust(8).ljust(20) }.join
    end
    parsed = PayrollImport::RevelPdfParser.parse(path).find { |row| row[:employee_name] == affected_row[:name] }
    expect(parsed).to include(regular_hours: 40.0, overtime_hours: 0.0, doubletime_hours: 0.to_d, total_hours: 42.25)

    data = preview(pdf: portal_upload("revel.pdf", File.binread(path), PDF_MIME), workbook: workbook_upload("overtime_heavy"))
    expect(response).to have_http_status(:ok), response.body
    review = data.fetch("preview")
    expect(review.fetch("can_apply")).to be(false)
    affected = review.fetch("source_rows").find { |row| row["employee_id"] == worker.id }
    error = affected.fetch("errors").sole
    expect(error).to include("code" => "hours_do_not_reconcile", "severity" => "error",
      "message" => include("2.25 more hours", "Exclude this row", "in the worksheet"))
    expect(expect_apply_blocked(data)).to eq(error.fetch("message"))
    expect(run.payroll_items).to be_empty

    included = review.fetch("source_rows").find { |row| row["employee_id"] == other_worker.id }
    apply_import(data, rows: [
      { id: affected.fetch("id"), disposition: "excluded", disposition_reason: "Enter the hours and pay in the worksheet." },
      { id: included.fetch("id"), disposition: "included" }
    ])
    expect(response).to have_http_status(:ok), response.body
    expect(run.payroll_items.sole).to have_attributes(employee_id: other_worker.id, hours_worked: BigDecimal("39.00"))
  end

  it "matches an employee hired during the period by name in Revel and ID in the workbook" do
    hire = create_worker(IntakeGoldenWorkbooks::NEW_HIRE, hire_date: run.start_date + 8)
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 65), revel_row_for(hire, regular: 21.25)),
      workbook: workbook_upload("new_hire"))
    expect_golden("new_hire", mosa_preview(data))
  end

  it "stitches a wrapped Revel name, matches its typo, and takes the filename dates first" do
    row = revel_row_for(worker, regular: 61.25, name: "Mockbery,\nTestnia")
    pdf = pdf_upload(row, filename: "payroll_#{run.start_date}_00-00_to_#{run.end_date}_23-59.pdf",
      report_period: [ run.start_date - 14, run.end_date - 14 ])
    data = preview(pdf: pdf, workbook: workbook_upload("normal"))
    snapshot = mosa_preview(data)
    snapshot["name_review"] = data.fetch("preview").fetch("low_confidence_matches")
    expect_golden("wrapped_revel_name", snapshot)
  end

  it "explains a terminated employee in both sources without making either row payable" do
    former = create_worker(IntakeGoldenWorkbooks::TERMINATED, status: "terminated", termination_date: run.start_date + 4)
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 65), revel_row_for(former, regular: 18)),
      workbook: workbook_upload("terminated"))
    expect_golden("terminated", mosa_preview(data))
  end

  context "with an offset legal workweek" do
    let(:workweek_start) { (run.start_date.wday + 1) % 7 }

    it "requires saved legacy tip treatment before applying a direct loan deduction and clearing an imported bonus" do
      set_up_payroll_tax
      prior_amount = BigDecimal("23.75")
      item = create(:payroll_item, pay_period: run, employee: worker, import_source: "mosa_revel",
        bonus_source: "mosa_revel", bonus: prior_amount, imported_bonus: prior_amount)
      data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 72)), workbook: workbook_upload("legacy"))
      snapshot = mosa_preview(data)
      snapshot["apply_error"] = expect_apply_blocked(data, tips_paid_out_from_tips: true)
      expect(item.reload).to have_attributes(bonus: prior_amount, imported_bonus: prior_amount)

      post "/api/v1/admin/pay_periods/#{run.id}/import_tip_treatment", params: {
        import_id: data.fetch("import_id"), tips_paid_out_from_tips: true
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      apply_import(data)
      expect(response).to have_http_status(:ok), response.body
      item.reload
      snapshot["saved_payroll"] = saved_payroll(item).merge("imported_bonus" => item.imported_bonus.to_s("F"))
      expect_golden("legacy", snapshot)
    end
  end

  it "applies a PDF-only package after staff records the missing-workbook waiver" do
    set_up_payroll_tax
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 75.25)))
    snapshot = mosa_preview(data)
    snapshot["apply_error"] = expect_apply_blocked(data)
    expect(run.payroll_items).to be_empty
    apply_import(data, no_tips_or_loans: true)
    expect(response).to have_http_status(:ok), response.body
    record = PayrollImportRecord.find(data.fetch("import_id"))
    snapshot["source_waiver"] = record.raw_data.fetch("source_waivers").sole.except("user_id", "at")
    snapshot["saved_payroll"] = saved_payroll
    expect_golden("pdf_only", snapshot)
  end

  it "previews a workbook alone and refuses to apply it without Revel hours" do
    data = preview(workbook: workbook_upload("normal"))
    snapshot = mosa_preview(data)
    snapshot["apply_error"] = expect_apply_blocked(data, no_tips_or_loans: true)
    expect(run.payroll_items).to be_empty
    expect_golden("workbook_only", snapshot)
  end

  it "saves an owner's variable period pay and its scope evidence" do
    set_up_payroll_tax
    owner = create_worker(IntakeGoldenWorkbooks::OWNER, employment_type: "salary", salary_type: "variable", pay_rate: 40_000)
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 55)), workbook: workbook_upload("owner_period_pay"))
    snapshot = mosa_preview(data)
    apply_import(data)
    expect(response).to have_http_status(:ok), response.body
    item = run.payroll_items.find_by!(employee: owner)
    snapshot["saved_payroll"] = saved_payroll(item).merge(
      "salary_override" => item.salary_override.to_s("F"),
      "period_pay_evidence" => item.custom_columns_data.fetch("period_pay_evidence")
    )
    expect_golden("owner_period_pay", snapshot)
  end

  it "uses the legacy fallback dates and reconciles an installment to the named loan" do
    type = DeductionType.create!(company: company, name: "Fixture installment", category: "post_tax", sub_category: "loan", active: true)
    loan = EmployeeLoan.create!(company: company, employee: worker, deduction_type: type, name: "Fixture installment",
      original_amount: 120, current_balance: 120, opening_balance: 120, balance_as_of: run.start_date,
      balance_source: "statement", payment_amount: 25, first_deduction_date: run.pay_date)
    worker.employee_deductions.create!(deduction_type: type, amount: 25, is_percentage: false, active: true)

    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 72)), workbook: workbook_upload("legacy_installment"))
    snapshot = mosa_preview(data)
    row = data.fetch("preview").fetch("matched").sole
    match = row.fetch("loan_reconciliation_matches").sole
    expect(match.fetch("employee_loan_id")).to eq(loan.id)
    amounts = %w[installment_beginning_balance installment_new_amount installment_payment installment_estimated_ending_balance]
    snapshot["installment"] = decimal_fields(row.slice(*amounts), *amounts)
    snapshot["loan_match"] = decimal_fields(match.except("employee_loan_id"), "amount")
    expect_golden("legacy_installment", snapshot)
  end

  it "previews the v1 workbook's separate bonus and one-payroll deduction columns" do
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 70)), workbook: workbook_upload("v1"))
    expect_golden("v1", mosa_preview(data))
  end

  it "applies a typed bonus and post-tax deduction with the workbook payee" do
    set_up_payroll_tax
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 70)), workbook: workbook_upload("one_time_components"))
    snapshot = mosa_preview(data)
    apply_import(data)
    expect(response).to have_http_status(:ok), response.body
    item = run.payroll_items.find_by!(employee: worker)
    snapshot["saved_components"] = item.payroll_item_field_entries.order(:label).map do |entry|
      decimal_fields(entry.attributes.slice("label", "kind", "tax_treatment", "amount", "source"), "amount")
        .merge("payee_name" => entry.metadata["payee_name"])
    end
    expect_golden("one_time_components", snapshot)
  end

  %w[blank_employee_id extra_hour_corrections_sheet loan_totals_mismatch loan_setup_change].each do |fixture|
    it "rejects #{fixture.tr('_', ' ')} before retaining a package" do
      data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 72)), workbook: workbook_upload(fixture))
      expect(response).to have_http_status(:unprocessable_entity)
      expect_golden(fixture, data)
      expect(run.payroll_intake_sessions).to be_empty
      expect(objects).to be_empty
    end
  end

  it "applies the current portal revision with the retained workbook and audits the import" do
    set_up_payroll_tax
    client = create(:user, company: company, role: "client")
    period_key = "#{run.start_date}_#{run.end_date}"
    send_revision = lambda do |**params|
      catalog = PayrollSubmissions::Catalog.new(company: company, today: run.end_date + 1)
      PayrollSubmissions::CreateRevision.new(company: company, actor: client, catalog: catalog,
        entry: catalog.resolve(period_key), params: params.merge(workbook_choice: "attach", no_changes: true)).call.submission
    end

    first = send_revision.call(revel_payroll: pdf_upload(revel_row_for(worker, regular: 68)), changes_workbook: workbook_upload("normal"))
    workbook = first.submission_documents.find_by!(role: "changes_workbook")
    second = send_revision.call(revel_payroll: pdf_upload(revel_row_for(worker, regular: 73, overtime: 2)),
      keep_document_ids: [ workbook.client_document_id ], based_on_revision: first.revision)

    data = preview(submission_id: second.id)
    snapshot = mosa_preview(data).merge("portal_source" => data.fetch("portal_source").slice("revision", "current", "workbook_choice"))
    expect(second.submission_documents.find_by!(role: "changes_workbook").sha256).to eq(workbook.sha256)
    expect(second.period).to be_pending_source_review

    apply_import(data, portal_source_id: data.dig("portal_source", "selection_id"))
    expect(response).to have_http_status(:ok), response.body
    applied_at = second.submission_imports.sole.applied_at
    expect(applied_at).to be_present
    expect(first.submission_imports).to be_empty
    expect(second.period.reload).not_to be_pending_source_review
    catalog = PayrollSubmissions::Catalog.new(company: company, today: run.end_date + 1)
    detail = PayrollSubmissions::Serializer.new(current_user: staff, catalog: catalog).detail(catalog.resolve(period_key))
    expect(detail.fetch(:submissions)).to include(include(id: second.id, imported_at: applied_at))
    event = second.period.status_events.last
    expect(event).to have_attributes(payroll_submission_id: second.id, actor: staff)
    audit = PayrollSubmissions::Audit.feed(second.period).find_by!(action: "payroll_submission_periods#import")
    expect(audit.metadata).to include("submission_id" => second.id, "current_submission_id" => second.id,
      "import_id" => data.fetch("import_id"), "source_package_id" => data.dig("source_package", "id"))
    expect(audit.user_id).to eq(staff.id)
    snapshot["import_event"] = event.attributes.slice("event", "from_status", "to_status")
    snapshot["saved_payroll"] = saved_payroll
    expect_golden("portal_revision", snapshot)
  end

  it "guards worksheet hours on re-import, then applies the new hours and removes an omitted reimbursement" do
    set_up_payroll_tax
    first = preview(pdf: pdf_upload(revel_row_for(worker, regular: 75.25, overtime: 1.5)), workbook: workbook_upload("normal"))
    apply_import(first)
    expect(response).to have_http_status(:ok), response.body
    item = run.payroll_items.find_by!(employee: worker)
    expect(item).to have_attributes(hours_worked: 75.25, overtime_hours: 1.5,
      reported_tips: BigDecimal("12.75"), tips_paid_out: BigDecimal("12.75"))
    reimbursement = item.payroll_item_field_entries.sole
    expect(reimbursement).to have_attributes(label: "Fixture supplies", amount: BigDecimal("12.34"), source: "import")
    expect(item.net_pay + item.total_deductions - item.gross_pay).to eq(BigDecimal("12.34"))
    item.update!(hours_worked: 73)
    corrected = preview(pdf: pdf_upload(revel_row_for(worker, regular: 76, overtime: 3.5)),
      workbook: workbook_upload("overtime_heavy"),
      supersedes_package_id: first.dig("source_package", "package_id"), supersession_reason: "Synthetic corrected hours")
    snapshot = mosa_preview(corrected)
    apply_import(corrected)
    expect(response).to have_http_status(:unprocessable_entity)
    snapshot["apply_error"] = response.parsed_body
    expect(item.reload.hours_worked).to eq(73)
    expect(item.payroll_item_field_entries.sole).to eq(reimbursement)

    apply_import(corrected, confirm_hours_overwrite: true)
    expect(response).to have_http_status(:ok), response.body
    item.reload
    expect(item.payroll_item_field_entries).to be_empty
    expect(item.net_pay + item.total_deductions).to eq(item.gross_pay)
    amounts = %w[gross_pay withholding_tax social_security_tax medicare_tax net_pay]
    snapshot["saved_payroll"] = saved_payroll(item).merge(
      decimal_fields(item.attributes.slice(*amounts), *amounts),
      "non_taxable_earnings" => item.payroll_item_earnings.where(category: "non_taxable").order(:label).pluck(:label)
    )
    expect_golden("hand_edit_reimport", snapshot)
  end

  def preview_spike(total_hours)
    text = <<~EMAIL
      Synthetic payroll email
      Pay period: 06/14/2026 - 06/27/2026
      Employee,Week 1 Hours,Week 2 Hours,Week 1 Tips,Week 2 Tips,Total Hours
      Testina Mockberry,38,42,5.25,7.50,#{total_hours}
    EMAIL
    post "/api/v1/admin/pay_periods/#{run.id}/payroll_intake_imports/preview", params: { source_type: "spike_email", pasted_text: text }

    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.fetch("import")
  end

  def spike_snapshot(result)
    result.slice("warnings").merge(
      "totals" => decimal_fields(result.fetch("totals"), "total_reported_tips", "total_tips_paid_out"),
      "rows" => result.fetch("rows").map do |row|
        fields = row.slice("employee_id", "source_employee_name", "status", "week1_hours", "week2_hours",
          "regular_hours", "overtime_hours", "reported_tips", "tips_paid_out", "warnings", "errors")
        decimal_fields(fields, "reported_tips", "tips_paid_out")
      end
    )
  end

  it "previews the alternate adapter's pasted email and its weekly totals check" do
    expect_golden("spike_email", spike_snapshot(preview_spike(85)))
  end

  it "applies a ready alternate-adapter row with weekly overtime and paid-out tips" do
    set_up_payroll_tax
    result = preview_spike(80)
    row = result.fetch("rows").sole
    expect(row.fetch("status")).to eq("ready")
    snapshot = spike_snapshot(result)
    post "/api/v1/admin/pay_periods/#{run.id}/payroll_intake_imports/#{result.fetch("id")}/apply", params: {
      rows: [ { id: row.fetch("id"), disposition: "included", employee_id: worker.id } ]
    }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors")).to eq([])
    expect(run.reload).to be_calculated
    expect(run.payroll_items.find_by!(employee: worker).import_source).to eq("spike_email")
    snapshot["saved_payroll"] = saved_payroll
    expect_golden("spike_email_apply", snapshot)
  end
end
