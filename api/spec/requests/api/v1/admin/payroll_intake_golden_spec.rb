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

  def pdf_upload(*rows, reported_total_hours: nil)
    path = build_revel_pdf(rows, period_start: run.start_date, period_end: run.end_date, reported_total_hours: reported_total_hours)
    portal_upload("revel.pdf", File.binread(path), PDF_MIME)
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
      "totals" => retained.totals,
      "rows" => review.fetch("source_rows").map do |source_row|
        id = source_row.fetch("id")
        row = normalized.fetch(id)
        source_row.slice("source_employee_name", "employee_id", "employee_name", "row_kind", "errors", "warnings").merge(
          "status" => row.status,
          "regular_hours" => row.regular_hours.to_f,
          "overtime_hours" => row.overtime_hours.to_f,
          "reported_tips" => row.reported_tips.to_f,
          "tips_paid_out" => row.tips_paid_out.to_f,
          "payroll_inputs" => matched[id]&.slice(
            "total_hours", "workbook_only", "pay_rate", "tips_boh", "tips_foh", "tip_pool",
            "loan_deduction", "loan_reconciliation_errors", "loan_reconciliation_warnings",
            "bonus", "period_pay", "payroll_components", "hand_edited_hours"
          )
        )
      end
    )
  end

  it "imports a normal v2 period with both tip pools and a typed reimbursement" do
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 75.25, overtime: 1.5)), workbook: workbook_upload("normal"))
    expect_golden("normal", mosa_preview(data))
  end

  it "keeps the reported overtime split even with a deliberately inconsistent Revel total" do
    # The printed total and the row total are deliberately out of balance.
    # Current intake preserves row evidence and uses the reported regular/OT split.
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 80, overtime: 31.75, total_hours: 125), reported_total_hours: 999),
      workbook: workbook_upload("overtime_heavy"))
    expect_golden("overtime_heavy", mosa_preview(data))
  end

  it "characterizes the current loss of double-time evidence between PDF parsing and review" do
    pdf = pdf_upload(revel_row_for(worker, regular: 72, doubletime_hours: 3))
    expect(PayrollImport::RevelPdfParser.parse_file(pdf).sole.fetch(:doubletime_hours)).to eq(3.0)
    data = preview(pdf: pdf, workbook: workbook_upload("overtime_heavy"))
    expect_golden("doubletime", mosa_preview(data))
  end

  it "matches an employee hired during the period by name in Revel and ID in the workbook" do
    hire = create_worker(IntakeGoldenWorkbooks::NEW_HIRE, hire_date: run.start_date + 8)
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 65), revel_row_for(hire, regular: 21.25)),
      workbook: workbook_upload("new_hire"))
    expect_golden("new_hire", mosa_preview(data))
  end

  it "explains a terminated employee in both sources without making either row payable" do
    former = create_worker(IntakeGoldenWorkbooks::TERMINATED, status: "terminated", termination_date: run.start_date + 4)
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 65), revel_row_for(former, regular: 18)),
      workbook: workbook_upload("terminated"))
    expect_golden("terminated", mosa_preview(data))
  end

  context "with an offset legal workweek" do
    let(:workweek_start) { (run.start_date.wday + 1) % 7 }

    it "reads the legacy row-4 layout and keeps both the legacy and date warnings" do
      data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 72)), workbook: workbook_upload("legacy"),
        tips_paid_out_from_tips: false)
      expect_golden("legacy", mosa_preview(data))
    end
  end

  it "previews a PDF alone as an incomplete package" do
    data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 75.25)))
    expect_golden("pdf_only", mosa_preview(data))
  end

  it "previews an unaccompanied workbook with tips but no imported hours" do
    data = preview(workbook: workbook_upload("normal"))
    expect_golden("workbook_only", mosa_preview(data))
  end

  it "keeps the amount and scope of one employee's variable period pay" do
    create_worker(IntakeGoldenWorkbooks::OWNER, employment_type: "salary", salary_type: "variable", pay_rate: 40_000)
    data = preview(workbook: workbook_upload("owner_period_pay"))
    expect_golden("owner_period_pay", mosa_preview(data))
  end

  %w[missing_id_column extra_hour_corrections_sheet loan_totals_mismatch].each do |fixture|
    it "rejects #{fixture.tr('_', ' ')} before retaining a package" do
      data = preview(pdf: pdf_upload(revel_row_for(worker, regular: 72)), workbook: workbook_upload(fixture))
      expect(response).to have_http_status(:unprocessable_entity)
      expect_golden(fixture, data)
      expect(run.payroll_intake_sessions).to be_empty
      expect(objects).to be_empty
    end
  end

  it "opens the current revised portal submission with the prior workbook retained" do
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
    expect_golden("portal_revision", mosa_preview(data).merge("portal_source" => data.fetch("portal_source").slice("revision", "current", "workbook_choice")))
    expect(second.submission_documents.find_by!(role: "changes_workbook").sha256).to eq(workbook.sha256)
  end

  it "guards worksheet hours on re-import, then saves the source split after confirmation" do
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: run.pay_date.year)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
    first = preview(pdf: pdf_upload(revel_row_for(worker, regular: 75.25, overtime: 1.5)), workbook: workbook_upload("overtime_heavy"))
    apply_import(first)
    expect(response).to have_http_status(:ok), response.body
    item = run.payroll_items.find_by!(employee: worker)
    expect(item).to have_attributes(hours_worked: 75.25, overtime_hours: 1.5, reported_tips: 11.50, tips_paid_out: 0)
    item.update!(hours_worked: 73)
    corrected = preview(pdf: pdf_upload(revel_row_for(worker, regular: 76, overtime: 3.5)),
      supersedes_package_id: first.dig("source_package", "package_id"), supersession_reason: "Synthetic corrected hours")
    snapshot = mosa_preview(corrected)
    apply_import(corrected)
    expect(response).to have_http_status(:unprocessable_entity)
    snapshot["apply_error"] = response.parsed_body
    expect(item.reload.hours_worked).to eq(73)

    apply_import(corrected, confirm_hours_overwrite: true)
    expect(response).to have_http_status(:ok), response.body
    snapshot["saved_payroll"] = item.reload.attributes.slice("hours_worked", "overtime_hours", "reported_tips", "tips_paid_out")
      .transform_values(&:to_f)
    expect_golden("hand_edit_reimport", snapshot)
  end

  it "previews the alternate adapter's pasted email and its weekly overtime and totals checks" do
    text = <<~EMAIL
      Synthetic payroll email
      Pay period: 06/14/2026 - 06/27/2026
      Employee,Week 1 Hours,Week 2 Hours,Week 1 Tips,Week 2 Tips,Total Hours
      Testina Mockberry,38,42,5.25,7.50,85
    EMAIL
    post "/api/v1/admin/pay_periods/#{run.id}/payroll_intake_imports/preview", params: { source_type: "spike_email", pasted_text: text }

    expect(response).to have_http_status(:ok), response.body
    result = response.parsed_body.fetch("import")
    expect_golden("spike_email", result.slice("totals", "warnings").merge(
      "rows" => result.fetch("rows").map do |row|
        row.slice("employee_id", "source_employee_name", "status", "week1_hours", "week2_hours",
          "regular_hours", "overtime_hours", "reported_tips", "tips_paid_out", "warnings", "errors")
      end
    ))
  end
end
