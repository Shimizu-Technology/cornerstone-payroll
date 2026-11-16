# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Portal-origin MoSa import review", type: :request do
  let!(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:staff) { create(:user, company: company, role: "admin") }
  let!(:employee) { create(:employee, company: company, first_name: "Avery", last_name: "Example", pay_rate: 10) }
  let!(:run) { create(:pay_period, company: company) }
  let!(:period) { PayrollSubmissionPeriod.create!(company: company, pay_period: run, source: "pay_period", start_date: run.start_date, end_date: run.end_date) }
  let(:url) { "/api/v1/admin/pay_periods/#{run.id}" }
  let(:objects) { {} }
  let(:storage) do
    entries = objects
    Object.new.tap do |store|
      store.define_singleton_method(:upload) { |key, data, **| entries[key] = data }
      store.define_singleton_method(:download_with_limit) do |key, max_bytes:|
        bytes = entries.fetch(key)
        raise R2StorageService::DownloadError, "File exceeds limit" if bytes.bytesize > max_bytes
        bytes
      end
      store.define_singleton_method(:delete) { |key| entries.delete(key) }
    end
  end

  before do
    allow(ClientDocumentScanner).to receive(:adapter).and_return(ClientDocumentScanner::Noop.new)
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: run.pay_date.year)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
    stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
    allow(R2StorageService).to receive(:new).and_return(storage)
    CompanyWorkweek.create!(company: company, starts_on_weekday: run.start_date.wday, starts_at_minutes: 0,
      timezone: "Pacific/Guam", effective_on: run.start_date, source: "operator_confirmed", confirmation_status: "confirmed",
      confirmed_by: staff, confirmed_at: Time.current, notes: "Synthetic confirmed workweek")
  end

  def revision(rev: 1, bytes: nil, workbook: false)
    submission = period.submissions.create!(company: company, revision: rev, submitted_by: staff, submitted_at: Time.current,
      content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32),
      change_rows: [ { kind: "wage_change", employee_id: employee.id, new_wage: "99.00", wage_unit: "hourly" } ])
    bytes ||= File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, overtime_hours: 2, regular_pay: 9999 } ],
      period_start: run.start_date, period_end: run.end_date))
    add_source(submission, bytes, "revel_payroll", "revel.pdf", "application/pdf")
    if workbook
      add_source(submission, PayrollImport::MosaSupplementalTemplate.new(run).generate, "changes_workbook", "changes.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    end
    submission
  end

  def add_source(submission, bytes, role, name, mime)
    key = "synthetic-portal/#{SecureRandom.uuid}/#{name}"
    objects[key] = bytes
    document = ClientDocument.create!(company: company, uploaded_by: staff, title: name, file_name: name, file_key: key,
      content_type: mime, file_size: bytes.bytesize, category: "payroll_source",
      visible_to_client: true, scan_status: ClientDocumentScanner.adapter.initial_status)
    submission.submission_documents.create!(company: company, client_document: document, role: role,
      position: submission.submission_documents.count, sha256: Digest::SHA256.hexdigest(bytes), file_name_snapshot: name, file_size_snapshot: bytes.bytesize)
  end

  def preview(source, **options)
    post "#{url}/preview_import", params: { submission_id: source.id, **options }, as: :json
    response.parsed_body
  end

  def apply(data)
    post "#{url}/apply_import", params: { import_id: data["import_id"], portal_source_id: data.dig("portal_source", "selection_id") }, as: :json
  end

  def workbook_upload
    portal_upload("downloaded.xlsx", PayrollImport::MosaSupplementalTemplate.new(run).generate,
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  def pay_run_preview(source)
    pdf = source.revel_document
    post "#{url}/preview_import", params: { pdf_file: portal_upload("revel.pdf", objects.fetch(pdf.client_document.file_key), "application/pdf"), excel_file: workbook_upload }
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  it "shows stale None before apply and retains the warning in the response and import note" do
    field = PayrollStandingChange.create!(company: company, employee: employee, kind: "extra_hours",
      employee_wage_rate: create(:employee_wage_rate, employee: employee), label: "Addison's hours", required: false)
    source = revision(workbook: true)
    source.update_columns(change_rows: [ { "kind" => "extra_hours", "employee_id" => employee.id,
      "employee_wage_rate_id" => field.employee_wage_rate_id, "standing_change_id" => field.id,
      "label" => field.label, "skipped" => true } ])
    field.update!(allow_none: false)
    data = preview(source)
    expect(response).to have_http_status(:ok), response.body
    warning = data.dig("client_change_prefill", "manual_review_warnings").sole
    expect(warning).to include("Addison's hours", "Enter the value or ask the client")
    apply(data)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body["manual_review_warnings"]).to include(warning)
    expect(response.parsed_body["client_change_decisions"]).to include(include("decision" => "stale_none", "reason" => warning))
    expect(period.status_events.last.note).to include(warning)
    expect(PayrollImportRecord.find(data["import_id"]).raw_data["client_change_decisions"]).to include(include("decision" => "stale_none", "reason" => warning))
    expect(PayrollEntryResolution.where(pay_period: run)).to be_empty
  end

  it "retains and verifies a staff workbook against a link revision without changing the client evidence" do
    source = revision
    source.update_columns(workbook_choice: "link", changes_link_url: "https://example.test/workbook")
    original = source.reload.attributes
    post "#{url}/preview_import", params: { submission_id: source.id, staff_workbook: workbook_upload }
    expect(response).to have_http_status(:ok), response.body
    data = response.parsed_body
    selection = PayrollSubmissionImport.find(data.dig("portal_source", "selection_id"))
    evidence = selection.staff_workbook_document
    expect(evidence).to have_attributes(source_role: "supplemental_workbook", verification_status: "verified", filename: "downloaded.xlsx")
    expect(selection).to have_attributes(staff_workbook_attached_by: staff, staff_workbook_attached_at: be_present)
    expect(data.dig("portal_source", "staff_workbook")).to include("filename" => "downloaded.xlsx", "sha256" => evidence.sha256, "attached_by_name" => staff.name)
    expect(Digest::SHA256.hexdigest(objects.fetch(evidence.storage_reference))).to eq(evidence.sha256)
    expect(source.reload.attributes).to eq(original)
    expect(source.submission_documents.count).to eq(1)
    expect { selection.update!(staff_workbook_attached_at: 1.day.ago) }.to raise_error(ActiveRecord::RecordInvalid)
    selection.reload
    apply(data)
    expect(response).to have_http_status(:ok), response.body
    expect(run.reload.pending_portal_submission?).to be(false)
    catalog = PayrollSubmissions::Catalog.new(company: company)
    detail = PayrollSubmissions::Serializer.new(current_user: staff, catalog: catalog).detail(catalog.resolve(period.id))
    expect(detail[:submissions].first[:imports].sole[:staff_workbook]).to include(filename: "downloaded.xlsx", sha256: evidence.sha256, attached_by_name: staff.name)
  end

  it "refuses staff workbooks for revisions without links or already containing workbooks" do
    source = revision(workbook: true)
    post "#{url}/preview_import", params: { submission_id: source.id, staff_workbook: workbook_upload }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("only supplement")
    expect(PayrollIntakeSession.count).to eq(0)
  end

  it "refuses non-Excel staff evidence and rejects retained staff workbook tampering on apply" do
    source = revision
    source.update_columns(workbook_choice: "link", changes_link_url: "https://example.test/workbook")
    post "#{url}/preview_import", params: { submission_id: source.id, staff_workbook: synthetic_pdf }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PayrollIntakeSession.count).to eq(0)
    post "#{url}/preview_import", params: { submission_id: source.id, staff_workbook: workbook_upload }
    expect(response).to have_http_status(:ok), response.body
    data = response.parsed_body
    evidence = PayrollSubmissionImport.find(data.dig("portal_source", "selection_id")).staff_workbook_document
    objects[evidence.storage_reference] = "changed bytes"
    apply(data)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(run.payroll_items).to be_empty
    expect(run.reload.pending_portal_submission?).to be(true)
    expect(evidence.reload.verification_status).to eq("failed")
  end

  it "points the pay run at the same-date revision that blocks it after its dates move, in the update response too" do
    set_aside = revision
    period.transition!("resolve_source", actor: staff, submission: set_aside, note: "Used the emailed files")
    expect(run.reload.pending_portal_submission?).to be(false)
    later = PayrollSubmissionPeriod.create!(company: company, source: "schedule", start_date: run.end_date + 1, end_date: run.end_date + 14)
    waiting = later.submissions.create!(company: company, revision: 1, submitted_by: staff, submitted_at: Time.current,
      content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32), change_rows: [])
    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    get url
    expect(response.parsed_body.dig("pay_period", "client_files")).to include("period_id" => period.id, "status" => "set aside", "blocks_calculation" => false)
    patch url, params: { pay_period: { start_date: later.start_date, end_date: later.end_date, pay_date: later.end_date + 5 } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("pay_period", "client_files")).to include("period_id" => later.id, "submission_id" => waiting.id, "status" => "waiting", "blocks_calculation" => true)
    get "/api/v1/admin/pay_periods"
    expect(response.parsed_body.fetch("pay_periods").pluck("client_files").compact).to be_empty
  end

  it "explicitly links pay-run Import MoSa to the current pending revision only on successful apply" do
    source = revision
    data = pay_run_preview(source)
    expect(data.dig("pending_portal_source", "submission_id")).to eq(source.id)
    post "#{url}/apply_import", params: { import_id: data["import_id"] }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(run.reload.pending_portal_submission?).to be(true)
    post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: source.id }, as: :json
    expect(response).to have_http_status(:ok), response.body
    selection = source.submission_imports.sole
    expect(selection).to have_attributes(source_route: "pay_run", selected_by: staff, applied_at: be_present)
    expect(run.reload.pending_portal_submission?).to be(false)
    audit = PayrollSubmissions::Audit.feed(period).find_by!(action: "payroll_submission_periods#import")
    expect(audit.metadata).to include("source_route" => "pay_run", "submission_id" => source.id, "import_id" => data["import_id"])
  end

  it "claims a schedule revision created before its matching pay run, only on successful apply" do
    source = revision
    period.update!(pay_period: nil)
    data = pay_run_preview(source)
    expect(data.dig("pending_portal_source", "submission_id")).to eq(source.id)
    expect(period.reload.pay_period_id).to be_nil
    post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: source.id }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(period.reload.pay_period_id).to eq(run.id)
    expect(run.reload.pending_portal_submission?).to be(false)
  end

  it "previews a pay-run import linked to a schedule revision that has no pay run yet" do
    source = revision
    period.update!(pay_period: nil, source: "schedule")
    pdf = source.revel_document
    post "#{url}/preview_import", params: { pdf_file: portal_upload("revel.pdf", objects.fetch(pdf.client_document.file_key), "application/pdf"),
      excel_file: workbook_upload, use_submission_id: source.id }
    expect(response).to have_http_status(:ok), response.body
    expect(period.reload.pay_period_id).to be_nil
  end

  [ false, true ].each do |schedule_period|
    it "keeps a failed saved-job selection retryable (schedule period: #{schedule_period})" do
      source = revision
      period.update!(pay_period: nil, source: "schedule") if schedule_period
      data = pay_run_preview(source)
      post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: source.id,
        wage_rate_choices: { employee.id.to_s => 999999 } }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("saved rates")
      expect(PayrollSubmissionImport.count).to eq(0)
      expect(period.reload.pay_period_id).to eq(schedule_period ? nil : run.id)
      expect(PayrollImportRecord.find(data["import_id"]).status).to eq("previewed")
      get "#{url}/current_import"
      expect(response.parsed_body["portal_source"]).to be_nil
      expect(response.parsed_body.dig("pending_portal_source", "submission_id")).to eq(source.id)
      post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: source.id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(source.submission_imports.sole).to have_attributes(source_route: "pay_run", applied_at: be_present)
      expect(period.reload.pay_period_id).to eq(run.id)
      expect(run.reload.pending_portal_submission?).to be(false)
    end
  end

  it "keeps a schedule revision retryable after an unexpected apply exception" do
    source = revision
    period.update!(pay_period: nil, source: "schedule")
    data = pay_run_preview(source)
    allow_any_instance_of(PayrollIntake::SourcePackageVerifier).to receive(:verify!).and_raise(StandardError, "verification interrupted")
    post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: source.id }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("verification interrupted")
    expect(PayrollSubmissionImport.count).to eq(0)
    expect(period.reload.pay_period_id).to be_nil
    expect(PayrollImportRecord.find(data["import_id"]).status).to eq("previewed")
    allow_any_instance_of(PayrollIntake::SourcePackageVerifier).to receive(:verify!).and_call_original
    post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: source.id }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(period.reload.pay_period_id).to eq(run.id)
    expect(source.submission_imports.sole.applied_at).to be_present
  end

  it "includes the pending revision checklist, notes and workbook choice in pay-run review" do
    source = revision
    source.update_columns(workbook_choice: "link", changes_link_url: "https://example.test/corrected", notes: "Check owner pay and the new hire")
    data = pay_run_preview(source)
    expect(data["pending_portal_source"]).to include("period_id" => period.id, "workbook_choice" => "link",
      "changes_link_url" => "https://example.test/corrected", "notes" => "Check owner pay and the new hire", "no_changes" => false)
    expect(data.dig("pending_portal_source", "changes").sole).to include("kind" => "wage_change", "label" => "Wage change", "employee_name" => employee.full_name, "new_wage" => "99.00")
  end

  it "does not consume a regular client revision after the linked run changes to a special purpose" do
    source = revision
    data = pay_run_preview(source)
    run.update_columns(run_purpose: "bonus")
    post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: source.id }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("matching regular pay run")
    expect(source.submission_imports).to be_empty
    expect(run.reload.pending_portal_submission?).to be(true)
  end

  it "refuses old, cross-company and cross-period revision selections" do
    old = revision
    data = pay_run_preview(old)
    current = revision(rev: 2)
    foreign_company = create(:company)
    foreign_period = PayrollSubmissionPeriod.create!(company: foreign_company, start_date: run.start_date, end_date: run.end_date, source: "pay_period")
    other_period = PayrollSubmissionPeriod.create!(company: company, start_date: run.start_date - 14, end_date: run.end_date - 14, source: "pay_period")
    invalid = [ old.id, foreign_period.submissions.create!(company: foreign_company, revision: 1, submitted_at: Time.current, content_fingerprint: "c", request_fingerprint: "r").id,
      other_period.submissions.create!(company: company, revision: 1, submitted_at: Time.current, content_fingerprint: "c", request_fingerprint: "r").id ]
    invalid.each do |id|
      post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: id }, as: :json
      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(PayrollSubmissionImport.count).to eq(0)
      expect(run.reload.pending_portal_submission?).to be(true)
    end
    expect(period.current_submission).to eq(current)
  end

  it "rolls back a pay-run revision link if applying a payroll row fails" do
    source = revision
    data = pay_run_preview(source)
    allow_any_instance_of(PayrollImport::ImportService).to receive(:apply!).and_return(success: [], skipped: [], errors: [ { error: "row failed" } ])
    post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: source.id }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(source.submission_imports).to be_empty
    expect(run.reload.pending_portal_submission?).to be(true)
    allow_any_instance_of(PayrollImport::ImportService).to receive(:apply!).and_call_original
    post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: source.id }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(source.submission_imports.sole.applied_at).to be_present
  end

  it "also warns on a pay-run upload without any portal revision or workbook" do
    bytes = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, regular_pay: 400 } ],
      period_start: run.start_date, period_end: run.end_date))
    post "#{url}/preview_import", params: { pdf_file: portal_upload("revel.pdf", bytes, "application/pdf") }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("preview", "source_warnings")).to include(include("code" => "missing_workbook", "severity" => "warning"))
    expect(response.parsed_body["portal_source"]).to be_nil
  end

  it "warns for missing workbook, distinguishes an explicit none, and notes zero workbook tips" do
    source = revision
    data = preview(source)
    expect(data.dig("preview", "source_warnings")).to include(include("code" => "missing_workbook", "message" => "No tips or loans: the workbook wasn't included"))
    source.update_columns(workbook_choice: "none")
    data = preview(source)
    expect(data.dig("preview", "source_warnings")).to include(include("code" => "client_no_tips_or_loans", "severity" => "info"))
    expect(data.dig("preview", "can_apply")).to be(true)
    source2 = revision(rev: 2, workbook: true)
    data = preview(source2, supersedes_package_id: data.dig("source_package", "package_id"), supersession_reason: "Workbook added")
    expect(response).to have_http_status(:ok), response.body
    expect(data.dig("preview", "source_warnings")).to include(include("code" => "zero_workbook_tips", "severity" => "info"))
  end

  it "bridges synthetic #433 files, deduplicates retries, applies once and retains independent bytes and both-way provenance" do
    source = revision(workbook: true)
    data = preview(source)
    expect(response).to have_http_status(:ok), response.body
    expect(data.dig("portal_source", "changes").first).to include("new_wage" => "99.00", "employee_name" => "Avery Example")
    record = PayrollImportRecord.find(data.fetch("import_id"))
    expect(source.payroll_imports).to include(record)
    expect(record.payroll_submissions).to include(source)
    record.payroll_intake_session.documents.each do |copy|
      original = copy.payroll_submission_document
      expect(copy.storage_reference).not_to eq(original.client_document.file_key)
      expect(objects.fetch(copy.storage_reference)).to eq(objects.fetch(original.client_document.file_key))
      expect(copy.sha256).to eq(original.sha256)
    end
    expect(preview(source)).to include("duplicate" => true, "import_id" => record.id)
    expect(PayrollSubmissionImport.count).to eq(1)
    apply(data)
    expect(response).to have_http_status(:ok), response.body
    expect(run.payroll_items.sole).to have_attributes(hours_worked: 40, overtime_hours: 2, pay_rate: 10)
    expect(employee.reload.pay_rate).to eq(10) # checklist wage is never applied
    expect(source.submission_imports.sole.applied_at).to be_present
    expect(period.status_events.last.event).to eq("import")
    expect(PayrollSubmissions::Audit.feed(period).pluck(:action)).to include("payroll_submission_periods#import")
    expect(PortalNotificationEvent.where(event_type: "payroll_submission_imported").count).to eq(1)
    expect(run.reload.pending_portal_submission?).to be(false)
    saved = run.payroll_items.sole.attributes
    apply(data)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(run.payroll_items.sole.attributes).to eq(saved)
    expect(preview(source)["error"]).to match(/applied/)
    expect(source.submission_documents.count).to eq(2)
    expect(source.revel_document.client_document.destroy).to be(false)
  end

  it "rejects wrong full Revel dates without retaining an intake package" do
    bytes = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, regular_pay: 400 } ], period_start: run.start_date - 14, period_end: run.end_date - 14))
    preview(revision(bytes: bytes))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PayrollIntakeSession.count).to eq(0)
  end

  it "accepts exactly 8 MiB and rejects 8 MiB plus one before parsing" do
    bytes = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, regular_pay: 400 } ], period_start: run.start_date, period_end: run.end_date))
    tail = bytes.rindex("startxref")
    at_limit = bytes[0...tail] + " " * (PayrollIntake::PreviewService::MAX_FILE_BYTES - bytes.bytesize) + bytes[tail..]
    source = revision(bytes: at_limit)
    preview(source)
    expect(response).to have_http_status(:ok), response.body
    too_big = revision(rev: 2, bytes: bytes.ljust(PayrollIntake::PreviewService::MAX_FILE_BYTES + 1, " "))
    expect(PayrollIntake::Adapters::MosaRevel).not_to receive(:new)
    preview(too_big)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/exceeds/)
  end

  it "rejects missing Revel roles" do
    source = revision
    PayrollSubmissionDocument.where(payroll_submission_id: source.id).delete_all
    preview(source)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PayrollIntakeSession.count).to eq(0)
  end

  it "allows supporting attachments as retained evidence but never parses them" do
    source = revision
    add_source(source, "supporting synthetic data", "attachment", "support.txt", "text/plain")
    data = preview(source)
    expect(response).to have_http_status(:ok), response.body
    expect(data.dig("source_package", "source_count")).to eq(1)
    expect(source.submission_documents.count).to eq(2)
  end

  it "enforces the one-file-per-source-role database constraints" do
    source = revision
    expect do
      PayrollSubmissionDocument.transaction(requires_new: true) do
        add_source(source, "%PDF-1.4 extra", "revel_payroll", "extra.pdf", "application/pdf")
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects same-size changed bytes before the parser or any source retention" do
    source = revision
    key = source.revel_document.client_document.file_key
    objects[key] = objects[key].dup.tap { |data| data.setbyte(10, data.getbyte(10) ^ 1) }
    expect(PayrollIntake::PreviewService).not_to receive(:new)
    preview(source)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/checksum/)
  end

  %w[pending infected error].each do |scan|
    it "rejects a #{scan} scan" do
      source = revision
      source.revel_document.client_document.update!(scan_status: scan)
      expect(PayrollIntake::PreviewService).not_to receive(:new)
      preview(source)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(PayrollIntakeSession.count).to eq(0)
    end
  end

  it "imports not_scanned portal sources with the default Noop adapter" do
    source = revision(workbook: true)
    expect(source.submission_documents.map { |link| link.client_document.scan_status }).to eq(%w[not_scanned not_scanned])
    data = preview(source)
    expect(response).to have_http_status(:ok), response.body
    apply(data)
    expect(response).to have_http_status(:ok), response.body
    expect(source.submission_imports.sole.applied_at).to be_present
    expect(run.payroll_items.sole).to have_attributes(hours_worked: 40, overtime_hours: 2, pay_rate: 10)
  end

  context "with an enforcing scanner adapter" do
    before do
      adapter = double("enforcing intake adapter", initial_status: "not_scanned")
      allow(adapter).to receive(:allowed?) { |document:, purpose:| purpose == :intake && document.scan_status == "clean" }
      allow(ClientDocumentScanner).to receive(:adapter).and_return(adapter)
    end

    %w[not_scanned pending infected error].each do |status|
      it "refuses #{status} files before parsing" do
        source = revision
        source.revel_document.client_document.update!(scan_status: status)
        expect(PayrollIntake::PreviewService).not_to receive(:new)
        preview(source)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(PayrollIntakeSession.count).to eq(0)
      end
    end

    it "accepts a clean source allowed by the configured adapter" do
      source = revision
      source.revel_document.client_document.update!(scan_status: "clean")
      preview(source)
      expect(response).to have_http_status(:ok), response.body
    end
  end

  it "requires an explicit audited superseded choice and rechecks newer corrections at apply" do
    old = revision
    current = revision(rev: 2)
    preview(old)
    expect(response).to have_http_status(:unprocessable_entity)
    data = preview(old, superseded_reason: "Client confirmed revision 2 was sent for the wrong period")
    expect(response).to have_http_status(:ok), response.body
    expect(PayrollSubmissions::Audit.feed(period).first.metadata).to include("superseded_reason" => "Client confirmed revision 2 was sent for the wrong period", "current_submission_id" => current.id)
    revision(rev: 3)
    apply(data)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/newer portal revision/)
    expect(run.payroll_items.count).to eq(0)
    expect(old.submission_imports.sole.applied_at).to be_nil
  end

  it "reuses the retained manifest across portal revisions without losing the selected checklist" do
    old = revision
    data = preview(old)
    bytes = objects.fetch(old.revel_document.client_document.file_key)
    current = revision(rev: 2, bytes: bytes)
    latest = preview(current)
    expect(response).to have_http_status(:ok), response.body
    expect(latest["import_id"]).to eq(data["import_id"])
    expect(latest.dig("portal_source", "submission_id")).to eq(current.id)
    expect(PayrollSubmissionImport.count).to eq(2)
    apply(data)
    expect(response).to have_http_status(:unprocessable_entity)
    apply(latest)
    expect(response).to have_http_status(:ok), response.body
  end

  it "marks a reopened review non-current after a newer portal revision arrives" do
    old = revision
    data = preview(old)
    revision(rev: 2)
    get "#{url}/current_import"
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("portal_source", "submission_id")).to eq(old.id)
    expect(response.parsed_body.dig("portal_source", "current")).to be(false)
    expect(old.submission_imports.sole.current_submission_id).to eq(old.id)
    apply(data)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(run.payroll_items).to be_empty
  end

  %w[draft_ready approved paid].each do |status|
    %w[import resolve_source].each do |event|
      it "records #{event} as status-preserving evidence for a #{status} portal period" do
        source = revision
        changed_at = 1.day.ago.change(usec: 0)
        period.update!(status: status, status_changed_at: changed_at, status_changed_by: staff)
        if event == "import"
          data = preview(source)
          apply(data)
        else
          post "#{url}/resolve_portal_source", params: { submission_id: source.id, reason: "Retain as supporting evidence only" }, as: :json
        end
        expect(response).to have_http_status(:ok), response.body
        expect(period.reload).to have_attributes(status: status, status_changed_at: changed_at, status_changed_by: staff)
        expect(PayrollSubmissionPeriod::EVENTS.fetch(event)[:to]).to eq(:unchanged)
        expect(period.status_events.last).to have_attributes(event: event, from_status: status, to_status: status)
        expect(run.reload.pending_portal_submission?).to be(false)
      end
    end
  end

  %w[approved committed].each do |status|
    it "blocks portal preview and apply into a #{status} run" do
      source = revision
      data = preview(source)
      run.update_columns(status: status)
      apply(data)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(run.payroll_items.count).to eq(0)
      preview(source)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(run.reload.status).to eq(status)
    end
  end

  it "blocks calculation, approval and commit for a pending source and supports an explicit audited disposition" do
    source = revision
    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    expect { post "#{url}/run_payroll", as: :json }.not_to change(PayrollItem, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/pending portal revision/)
    expect(run.update(status: "calculated")).to be(false)
    service = PayPeriodLifecycleService.new(pay_period: run.reload, actor: staff)
    expect { service.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /pending portal revision/)
    expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /pending portal revision/)
    post "#{url}/resolve_portal_source", params: { submission_id: source.id, reason: "Wrong period; client will resend. Do not use these files." }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(run.reload.pending_portal_submission?).to be(false)
    expect(period.status_events.last.event).to eq("resolve_source")
    revision(rev: 2)
    expect(run.pending_portal_submission?).to be(true)
  end

  it "keeps a linked pending revision gated after the run dates change" do
    revision
    run.update!(start_date: run.start_date + 1, end_date: run.end_date + 1)
    expect(run.reload.pending_portal_submission?).to be(true)
    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    expect { post "#{url}/run_payroll", as: :json }.not_to change(PayrollItem, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/pending portal revision/)
    service = PayPeriodLifecycleService.new(pay_period: run.reload, actor: staff)
    expect { service.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /pending portal revision/)
    expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /pending portal revision/)
  end

  it "blocks a second same-date regular run from calculation, approval and commit" do
    revision
    duplicate = create(:pay_period, company: company, start_date: run.start_date, end_date: run.end_date, pay_date: run.pay_date)
    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    expect { post "/api/v1/admin/pay_periods/#{duplicate.id}/run_payroll", as: :json }.not_to change(PayrollItem, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/pending portal revision/)
    expect(duplicate.update(status: "calculated")).to be(false)
    service = PayPeriodLifecycleService.new(pay_period: duplicate.reload, actor: staff)
    expect { service.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /pending portal revision/)
    expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /pending portal revision/)
  end

  it "lets only the catalog's eligible regular run claim an unlinked period" do
    source = revision
    period.update!(pay_period: nil)
    supplemental = create(:pay_period, company: company, cycle: "supplemental", corrects_pay_period: run,
      start_date: run.start_date, end_date: run.end_date, pay_date: run.pay_date)
    expect(PayrollIntake::PreviewService).not_to receive(:new)
    post "/api/v1/admin/pay_periods/#{supplemental.id}/preview_import", params: { submission_id: source.id }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/matching regular pay run/)
    expect(period.reload.pay_period_id).to be_nil
    duplicate = create(:pay_period, company: company, start_date: run.start_date, end_date: run.end_date, pay_date: run.pay_date)
    preview(source)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(period.reload.pay_period_id).to be_nil
    expect(run.pending_portal_submission?).to be(true)
    expect(duplicate.pending_portal_submission?).to be(true)
  end

  it "claims an unlinked matching period for the catalog's regular run and refuses a second claimant" do
    source = revision
    period.update!(pay_period: nil)
    preview(source)
    expect(response).to have_http_status(:ok), response.body
    expect(period.reload.pay_period_id).to eq(run.id)
    duplicate = create(:pay_period, company: company, start_date: run.start_date, end_date: run.end_date, pay_date: run.pay_date)
    post "/api/v1/admin/pay_periods/#{duplicate.id}/preview_import", params: { submission_id: source.id }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/linked to another/)
    expect(period.reload.pay_period_id).to eq(run.id)
  end

  it "rejects dispositions through another same-date run without clearing the linked run's pending source" do
    source = revision
    duplicate = create(:pay_period, company: company, start_date: run.start_date, end_date: run.end_date, pay_date: run.pay_date)
    expect do
      post "/api/v1/admin/pay_periods/#{duplicate.id}/resolve_portal_source", params: { submission_id: source.id, reason: "Wrong run" }, as: :json
    end.not_to change(PayrollSubmissionStatusEvent, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(run.reload.pending_portal_submission?).to be(true)
    expect(PayrollSubmissions::Audit.feed(period).where(action: "payroll_submission_periods#resolve_source")).to be_empty
  end

  %w[preview_import apply_import resolve_portal_source].each do |action|
    it "rechecks write access after the financial locks before #{action}" do
      source = revision
      data = preview(source) if action == "apply_import"
      allow_any_instance_of(PayPeriod).to receive(:lock!).and_wrap_original do |method, *args|
        result = method.call(*args)
        User.where(id: staff.id).update_all(active: false)
        result
      end
      params = case action
      when "preview_import" then { submission_id: source.id }
      when "apply_import" then { import_id: data.fetch("import_id"), portal_source_id: data.dig("portal_source", "selection_id") }
      else { submission_id: source.id, reason: "Not used" }
      end
      post "#{url}/#{action}", params: params, as: :json
      expect(response).to have_http_status(:forbidden), response.body
      expect(response.parsed_body["code"]).to eq("company_context_unavailable")
      expect(run.payroll_items).to be_empty
      expect(period.status_events.where(event: %w[import resolve_source])).to be_empty
      expect(source.submission_imports.where.not(applied_at: nil)).to be_empty
    end
  end

  it "invalidates stale calculation at preview while keeping the correction itself non-mutating" do
    run.update_columns(status: "calculated", calculated_at: Time.current)
    source = revision
    expect(run.reload.status).to eq("calculated")
    preview(source)
    expect(response).to have_http_status(:ok), response.body
    expect(run.reload).to have_attributes(status: "draft")
    expect(run.intake_stale?).to be(true)
  end

  it "rolls back payroll, applied status, notification and Imported history when the Activity write fails" do
    source = revision
    data = preview(source)
    allow(PayrollSubmissions::Audit).to receive(:record!).and_raise("synthetic audit failure")
    apply(data)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(run.payroll_items.count).to eq(0)
    expect(run.reload.status).to eq("draft")
    expect(PayrollImportRecord.last.status).to eq("previewed")
    expect(source.submission_imports.sole.applied_at).to be_nil
    expect(period.status_events.where(event: "import")).to be_empty
    expect(PortalNotificationEvent.where(event_type: "payroll_submission_imported")).to be_empty
  end

  it "retains source files while rolling back an unmatched employee review" do
    source = revision(bytes: File.binread(build_revel_pdf([ { name: "Nobody, Synthetic", regular_hours: 40, regular_pay: 400 } ], period_start: run.start_date, period_end: run.end_date)))
    data = preview(source)
    apply(data)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(run.payroll_items.count).to eq(0)
    expect(source.submission_imports.sole.applied_at).to be_nil
    expect(objects).to have_key(source.revel_document.client_document.file_key)
  end

  it "does not resolve source review through the generic intake apply endpoint" do
    data = preview(revision)
    session = PayrollImportRecord.find(data.fetch("import_id")).payroll_intake_session
    expect do
      PayrollIntake::ApplyService.new(session: session, actor: staff).call
    end.to raise_error(ArgumentError, /MoSa import review/)
    expect(run.payroll_items.count).to eq(0)
  end

  it "cleans a new independent intake copy on preview audit failure while retaining original portal bytes" do
    source = revision
    original_keys = objects.keys
    allow(PayrollSubmissions::Audit).to receive(:record!).and_raise("synthetic preview audit failure")
    preview(source)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PayrollIntakeSession.count).to eq(0)
    expect(PayrollImportRecord.count).to eq(0)
    expect(PayrollSubmissionImport.count).to eq(0)
    expect(objects.keys).to eq(original_keys)
  end

  it "does not accept a submission from another company or period" do
    source = revision
    other_run = create(:pay_period, company: company, start_date: run.start_date + 14, end_date: run.end_date + 14, pay_date: run.pay_date + 14)
    post "/api/v1/admin/pay_periods/#{other_run.id}/preview_import", params: { submission_id: source.id }, as: :json
    expect(response).to have_http_status(:not_found)
    other = create(:company, payroll_intake_source_types: [ "mosa_revel" ])
    stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, other)
    preview(source)
    expect(response).to have_http_status(:forbidden)
    expect(PayrollSubmissionImport.count).to eq(0)
  end

  it "can explicitly choose an older source after reviewing the newer revision, with the reason retained on apply" do
    old = revision
    revision(rev: 2)
    data = preview(old, superseded_reason: "Client confirmed old source is correct and new revision is for another period")
    apply(data)
    expect(response).to have_http_status(:ok), response.body
    expect(run.reload.pending_portal_submission?).to be(false)
    expect(period.current_submission.submission_imports.where.not(applied_at: nil)).to be_empty
    expect(old.submission_imports.sole.applied_at).to be_present
    expect(period.status_events.last.note).to include("revision 1")
  end

  it "keeps a reused manual-upload package in MoSa review even after the portal source is dispositioned" do
    source = revision
    data = preview(source)
    session = PayrollImportRecord.find(data.fetch("import_id")).payroll_intake_session
    # A duplicate of an older manual upload has no initial portal document FK.
    session.documents.update_all(payroll_submission_document_id: nil)
    post "#{url}/resolve_portal_source", params: { submission_id: source.id, reason: "Only the supporting checklist needs separate manual handling" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(run.reload.pending_portal_submission?).to be(false)
    expect do
      PayrollIntake::ApplyService.new(session: session, actor: staff).call
    end.to raise_error(ArgumentError, /MoSa import review/)
    expect(run.payroll_items.count).to eq(0)
  end

  context "with a variable-pay owner in the files" do
    let!(:owner) do
      create(:employee, company: company, first_name: "Owner", last_name: "Example",
        employment_type: "salary", salary_type: "variable", pay_rate: 200_000)
    end
    let(:bytes) do
      File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, regular_pay: 400 },
        { name: "Example, Owner", regular_hours: 0, regular_pay: 0 } ], period_start: run.start_date, period_end: run.end_date))
    end

    def owner_row(payload)
      payload.dig("preview", "matched").find { |row| row["employee_id"] == owner.id }
    end

    it "saves each owner's pay during review, reopens the review with it, and applies" do
      data = preview(revision(bytes: bytes))
      expect(owner_row(data)).to include("period_pay_required" => true, "period_pay_missing" => true, "overwrite_required" => false)

      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      post "#{url}/payroll_items", params: { employee_id: owner.id, payroll_item: { employee_id: owner.id, salary_override: "4500.00" } }, as: :json
      expect(response).to have_http_status(:created), response.body

      get "#{url}/current_import"
      expect(response).to have_http_status(:ok), response.body
      expect(owner_row(response.parsed_body)).to include(
        "period_pay_missing" => false, "current_period_pay" => "4500.0", "period_pay_source" => "payroll_worksheet", "overwrite_required" => true
      )
      expect(response.parsed_body.dig("portal_source", "selection_id")).to eq(data.dig("portal_source", "selection_id"))

      post "#{url}/apply_import", params: { import_id: data["import_id"], portal_source_id: data.dig("portal_source", "selection_id"), force_overwrite: true }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(run.payroll_items.find_by!(employee: owner).salary_override).to eq(4500)
      expect(run.reload.pending_portal_submission?).to be(false)
    end

    it "reviews and saves separate pay for two owners absent from both files" do
      second = create(:employee, company: company, first_name: "Second", last_name: "Owner",
        employment_type: "salary", salary_type: "variable", pay_rate: 300_000)
      data = preview(revision)
      expect(response).to have_http_status(:ok), response.body
      rows = data.dig("preview", "matched").select { |row| [ owner.id, second.id ].include?(row["employee_id"]) }
      expect(rows.size).to eq(2)
      expect(rows).to all(include("payroll_setup_only" => true, "period_pay_missing" => true, "current_period_pay" => nil))
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      [ [ owner, "4500.00" ], [ second, "5200.00" ] ].each do |person, amount|
        post "#{url}/payroll_items", params: { employee_id: person.id, expected_import_id: data["import_id"],
          payroll_item: { employee_id: person.id, salary_override: amount } }, as: :json
        expect(response).to have_http_status(:created), response.body
      end
      get "#{url}/current_import"
      rows = response.parsed_body.dig("preview", "matched").select { |row| [ owner.id, second.id ].include?(row["employee_id"]) }
      expect(rows).to all(include("period_pay_missing" => false, "payroll_setup_only" => true))
      post "#{url}/apply_import", params: { import_id: data["import_id"], portal_source_id: data.dig("portal_source", "selection_id"), force_overwrite: true }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(run.payroll_items.find_by!(employee: owner).salary_override).to eq(4500)
      expect(run.payroll_items.find_by!(employee: second).salary_override).to eq(5200)
    end

    it "refuses a review's owner-pay save once the review is stale or pay was already entered" do
      data = preview(revision(bytes: bytes))
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      save = ->(amount, import_id) do
        post "#{url}/payroll_items", params: { employee_id: owner.id, expected_import_id: import_id,
          payroll_item: { employee_id: owner.id, salary_override: amount } }, as: :json
      end

      save.call("4500.00", data["import_id"] + 1)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["code"]).to eq("stale_import_review")
      expect(run.payroll_items.find_by(employee: owner)).to be_nil

      save.call("4500.00", data["import_id"])
      expect(response).to have_http_status(:created), response.body
      item = run.payroll_items.find_by!(employee: owner)

      patch "#{url}/payroll_items/#{item.id}", params: { expected_import_id: data["import_id"],
        payroll_item: { salary_override: "9999.00" } }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(item.reload.salary_override).to eq(4500)
    end

    it "refuses a review's owner-pay save after a newer portal revision arrives" do
      data = preview(revision(bytes: bytes))
      revision(rev: 2, bytes: bytes)
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      post "#{url}/payroll_items", params: { employee_id: owner.id, expected_import_id: data["import_id"],
        payroll_item: { employee_id: owner.id, salary_override: "4500.00" } }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(run.payroll_items.find_by(employee: owner)).to be_nil
    end

    it "counts an amount saved from the review as entered by hand even when it equals earlier workbook pay" do
      data = preview(revision(bytes: bytes))
      item = create(:payroll_item, pay_period: run, employee: owner, employment_type: "salary", salary_override: 4500,
        custom_columns_data: { "period_pay_evidence" => { "source_type" => "mosa_change_workbook" } })
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      patch "#{url}/payroll_items/#{item.id}", params: { expected_import_id: data["import_id"],
        payroll_item: { salary_override: "4500.00" } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      get "#{url}/current_import"
      expect(owner_row(response.parsed_body)).to include("period_pay_missing" => false, "period_pay_source" => "payroll_worksheet")
    end

    it "keeps refusing to apply while an owner has no pay of their own" do
      data = preview(revision(bytes: bytes))
      apply(data)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/Pay this period/)
      expect(run.reload.pending_portal_submission?).to be(true)
      get "#{url}/current_import"
      expect(owner_row(response.parsed_body)).to include("period_pay_missing" => true)
    end
  end
  describe "standing change review" do
    let!(:owner) { create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0) }
    let!(:manual_worker) { create(:employee, company: company, pay_rate: 35) }
    let!(:manual_job) { create(:employee_wage_rate, employee: manual_worker, label: "Maintenance", rate: 35) }

    def standing_source
      source = revision
      source.update_columns(change_rows: [
        { "kind" => "owner_pay", "employee_id" => owner.id, "amount" => "8421.13" },
        { "kind" => "extra_hours", "employee_id" => manual_worker.id, "employee_wage_rate_id" => manual_job.id,
          "wage_rate" => "35.0", "hours" => "68" }
      ])
      source
    end

    def reviewed_standing_params(data)
      { import_id: data.fetch("import_id"), confirm_client_changes: true,
        reviewed_changes: [ { change_index: 0, amount: "8421.13" }, { change_index: 1, hours: "68" } ] }
    end

    it "prefills the portal review without writes and atomically applies per-person pay and saved-job hours" do
      source = standing_source
      data = preview(source)
      expect(response).to have_http_status(:ok), response.body
      expect(data.dig("client_change_prefill", "rows")).to include(include("employee_id" => owner.id, "amount" => "8421.13"),
        include("employee_id" => manual_worker.id, "hours" => "68", "employee_wage_rate_id" => manual_job.id))
      expect(run.payroll_items).to be_empty
      apply(data)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Confirm")
      expect(run.payroll_items).to be_empty
      post "#{url}/apply_import", params: reviewed_standing_params(data).merge(portal_source_id: data.dig("portal_source", "selection_id")), as: :json
      expect(response).to have_http_status(:ok), response.body
      owner_item = run.payroll_items.find_by!(employee: owner)
      worker_item = run.payroll_items.find_by!(employee: manual_worker)
      expect(owner_item.salary_override).to eq(BigDecimal("8421.13"))
      expect(owner_item.custom_columns_data.dig("period_pay_evidence", "source_type")).to eq("client_submission")
      expect(worker_item.hours_worked).to eq(68)
      expect(worker_item.wage_rate_hours.sole).to include("employee_wage_rate_id" => manual_job.id, "rate" => 35.0, "regular_hours" => 68.0)
      expect(source.submission_imports.sole.applied_at).to be_present
      expect(run.reload.pending_portal_submission?).to be(false)
    end

    it "offers the same figures for pay-run linking and persists staff edits only on successful apply" do
      source = standing_source
      data = pay_run_preview(source)
      expect(data["client_change_prefill"]).to be_nil
      expect(data.dig("pending_change_prefill", "submission_id")).to eq(source.id)
      params = reviewed_standing_params(data).merge(use_submission_id: source.id)
      params[:reviewed_changes][0][:amount] = "8421.12"
      params[:reviewed_changes][0][:reason] = "Client confirmed corrected pay"
      params[:reviewed_changes][1][:hours] = "67.5"
      params[:reviewed_changes][1][:reason] = "Client confirmed corrected hours"
      post "#{url}/apply_import", params: params, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(run.payroll_items.find_by!(employee: owner).salary_override).to eq(BigDecimal("8421.12"))
      expect(run.payroll_items.find_by!(employee: manual_worker).hours_worked).to eq(BigDecimal("67.5"))
      expect(source.submission_imports.sole).to have_attributes(source_route: "pay_run", applied_at: be_present)
    end

    it "keeps Revel hours on their reviewed job and adds extra hours only to the submitted job" do
      base_job = create(:employee_wage_rate, employee: employee, label: "Service", rate: 10, is_primary: true)
      extra_job = create(:employee_wage_rate, employee: employee, label: "Maintenance", rate: 35)
      source = standing_source
      source.update_columns(change_rows: source.change_rows + [ { "kind" => "extra_hours", "employee_id" => employee.id,
        "employee_wage_rate_id" => extra_job.id, "wage_rate" => "35.0", "hours" => "3" } ])
      data = preview(source)
      input = reviewed_standing_params(data).merge(portal_source_id: data.dig("portal_source", "selection_id"),
        wage_rate_choices: { employee.id.to_s => base_job.id })
      input[:reviewed_changes] << { change_index: 2, hours: "3" }
      post "#{url}/apply_import", params: input, as: :json
      expect(response).to have_http_status(:ok), response.body
      item = run.payroll_items.find_by!(employee: employee)
      expect(item.hours_worked).to eq(43)
      expect(item.wage_rate_hours).to contain_exactly(
        include("employee_wage_rate_id" => base_job.id, "regular_hours" => 40.0, "overtime_hours" => 2.0, "rate" => 10.0),
        include("employee_wage_rate_id" => extra_job.id, "regular_hours" => 3.0, "overtime_hours" => 0.0, "rate" => 35.0))
    end

    it "replaces the previous client-only hours on corrected-source reimport instead of adding them twice" do
      source = standing_source
      data = preview(source)
      post "#{url}/apply_import", params: reviewed_standing_params(data).merge(portal_source_id: data.dig("portal_source", "selection_id")), as: :json
      expect(response).to have_http_status(:ok), response.body
      item = run.payroll_items.find_by!(employee: manual_worker)
      expect(item.hours_worked).to eq(68)
      expect(item.custom_columns_data.dig("client_change_evidence", "baseline_regular_hours")).to eq("0.0")
      client = create(:user, company: company, role: "client")
      corrected_pdf = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 41, overtime_hours: 2, regular_pay: 410 } ],
        period_start: run.start_date, period_end: run.end_date))
      second = revision(rev: 2, bytes: corrected_pdf)
      second.update_columns(change_rows: source.change_rows)
      period.transition!("submit", actor: client, submission: second)
      replacement = preview(second, supersedes_package_id: data.dig("source_package", "package_id"), supersession_reason: "Corrected source files")
      expect(response).to have_http_status(:ok), response.body
      input = reviewed_standing_params(replacement).merge(portal_source_id: replacement.dig("portal_source", "selection_id"))
      input[:reviewed_changes][1][:hours] = "67"
      input[:reviewed_changes][1][:reason] = "Client confirmed corrected hours"
      post "#{url}/apply_import", params: input, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.hours_worked).to eq(67)
      expect(item.wage_rate_hours.sole["regular_hours"]).to eq(67.0)
      item.update!(hours_worked: 66)
      next_pdf = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 42, overtime_hours: 2, regular_pay: 420 } ],
        period_start: run.start_date, period_end: run.end_date))
      third = revision(rev: 3, bytes: next_pdf)
      third.update_columns(change_rows: source.change_rows)
      period.transition!("submit", actor: client, submission: third)
      latest = preview(third, supersedes_package_id: replacement.dig("source_package", "package_id"), supersession_reason: "Another correction")
      expect(response).to have_http_status(:ok), response.body
      post "#{url}/apply_import", params: reviewed_standing_params(latest).merge(portal_source_id: latest.dig("portal_source", "selection_id")), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "row_errors").map { |error| error["error"] }.join).to include("Reconcile the worksheet hours")
      expect(item.reload.hours_worked).to eq(66)
    end

    def apply_standing(data, changes = reviewed_standing_params(data)[:reviewed_changes])
      post "#{url}/apply_import", params: { import_id: data.fetch("import_id"), confirm_client_changes: true,
        reviewed_changes: changes, portal_source_id: data.dig("portal_source", "selection_id") }, as: :json
      expect(response).to have_http_status(:ok), response.body
    end

    def identical_revision(source, rev:, changes:)
      next_source = period.submissions.create!(company: company, revision: rev, submitted_by: staff, submitted_at: Time.current,
        content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32),
        change_rows: changes, no_changes: changes.empty?, workbook_choice: source.workbook_choice)
      source.submission_documents.each do |link|
        add_source(next_source, objects.fetch(link.client_document.file_key), link.role, link.file_name_snapshot, link.client_document.content_type)
      end
      period.transition!("submit", actor: create(:user, company: company, role: "client"), submission: next_source)
      next_source
    end

    %w[skipped dropped].each do |mode|
      it "reviews byte-identical files with #{mode} changes and reapplies revision 1 exactly once" do
        source = standing_source
        add_source(source, PayrollImport::MosaSupplementalTemplate.new(run).generate, "changes_workbook", "changes.xlsx",
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        create(:payroll_item, company: company, pay_period: run, employee: manual_worker, hours_worked: 2,
          import_source: "mosa_revel", wage_rate_hours: [ { employee_wage_rate_id: manual_job.id, label: "Maintenance", rate: 35, regular_hours: 2, overtime_hours: 0 } ])
        first = preview(source)
        apply_standing(first)
        snapshot = -> { run.payroll_items.order(:employee_id).map { |item| item.attributes.slice("employee_id", "hours_worked", "overtime_hours", "wage_rate_hours", "salary_override", "gross_pay", "net_pay", "loan_deduction", "reported_tips") } }
        original = snapshot.call
        changes = mode == "skipped" ? source.change_rows.map { |row| row.merge("skipped" => true).except("amount", "hours") } : []
        second = identical_revision(source, rev: 2, changes: changes)
        data = preview(second)
        expect(response).to have_http_status(:ok), response.body
        package = PayrollImportRecord.find(data.fetch("import_id")).payroll_intake_session
        expect(package).to have_attributes(supersedes_id: PayrollImportRecord.find(first["import_id"]).payroll_intake_session_id,
          supersession_reason: "client revision 2: changes only")
        expect(package.documents.pluck(:sha256)).to match_array(source.submission_documents.pluck(:sha256))
        expect(data.dig("client_change_prefill", "removals").join).to include("68", manual_worker.full_name)
        expect(data.dig("preview", "matched").find { |row| row["employee_id"] == owner.id }).to include("period_pay_missing" => true)
        apply(data)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(snapshot.call).to eq(original)
        stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
        item = run.payroll_items.find_by!(employee: owner)
        patch "#{url}/payroll_items/#{item.id}", params: { expected_import_id: data["import_id"], payroll_item: { salary_override: "100" } }, as: :json
        expect(response).to have_http_status(:ok), response.body
        apply_standing(data, [])
        worker = run.payroll_items.find_by!(employee: manual_worker)
        expect(worker.hours_worked).to eq(2)
        expect(worker.wage_rate_hours.sum { |row| row["regular_hours"].to_d }).to eq(2)
        third = identical_revision(source, rev: 3, changes: source.change_rows)
        final = preview(third)
        expect(response).to have_http_status(:ok), response.body
        reviewed = reviewed_standing_params(final)[:reviewed_changes]
        reviewed.first.merge!(pay_choice: "client", saved_period_pay: "100.0")
        apply_standing(final, reviewed)
        expect(snapshot.call).to eq(original)
        expect(worker.reload.hours_worked).to eq(70)
        expect(worker.wage_rate_hours.sum { |row| row["regular_hours"].to_d }).to eq(70)
        preview(third)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include("revision was already applied")
        expect(PayrollIntakeSession.count).to eq(3)
      end
    end

    it "refuses an identical-files identical-changes resend without a replacement" do
      source = standing_source
      first = preview(source)
      apply_standing(first)
      second = identical_revision(source, rev: 2, changes: source.change_rows)
      expect { preview(second) }.not_to change(PayrollIntakeSession, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("repeats the already-applied files and changes")
      expect(run.payroll_items.find_by!(employee: manual_worker).hours_worked).to eq(68)
    end

    it "keeps plain duplicate protection and explicitly links an identical-files pay-run correction" do
      source = standing_source
      add_source(source, PayrollImport::MosaSupplementalTemplate.new(run).generate, "changes_workbook", "changes.xlsx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
      first = preview(source)
      apply_standing(first)
      second = identical_revision(source, rev: 2, changes: source.change_rows.map { |row| row["kind"] == "extra_hours" ? row.merge("hours" => "32") : row })
      files = -> { source.submission_documents.order(:position).map { |link| portal_upload(link.file_name_snapshot, objects.fetch(link.client_document.file_key), link.client_document.content_type) } }
      pdf, workbook = files.call
      post "#{url}/preview_import", params: { pdf_file: pdf, excel_file: workbook }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("already applied")
      expect(response.parsed_body.dig("details", "pending_submission_id")).to eq(second.id)
      pdf, workbook = files.call
      post "#{url}/preview_import", params: { pdf_file: pdf, excel_file: workbook, use_submission_id: second.id }
      expect(response).to have_http_status(:ok), response.body
      data = response.parsed_body
      reviewed = reviewed_standing_params(data)[:reviewed_changes]
      reviewed.last[:hours] = "32"
      post "#{url}/apply_import", params: { import_id: data["import_id"], use_submission_id: second.id,
        confirm_client_changes: true, reviewed_changes: reviewed }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(second.submission_imports.sole).to have_attributes(source_route: "pay_run", applied_at: be_present)
      expect(run.payroll_items.find_by!(employee: manual_worker).hours_worked).to eq(32)
      pdf, workbook = files.call
      post "#{url}/preview_import", params: { pdf_file: pdf, excel_file: workbook }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("superseded")
    end

    it "refuses a changes-only review after another client revision arrives" do
      source = standing_source
      first = preview(source)
      apply_standing(first)
      second = identical_revision(source, rev: 2, changes: source.change_rows.map { |row| row.merge("hours" => "32") })
      data = preview(second)
      expect(response).to have_http_status(:ok), response.body
      identical_revision(source, rev: 3, changes: source.change_rows)
      post "#{url}/apply_import", params: reviewed_standing_params(data).merge(portal_source_id: data.dig("portal_source", "selection_id")), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("newer portal revision")
      expect(run.payroll_items.find_by!(employee: manual_worker).hours_worked).to eq(68)
      expect(second.submission_imports.sole.applied_at).to be_nil
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      patch "#{url}/payroll_items/#{run.payroll_items.find_by!(employee: owner).id}",
        params: { expected_import_id: data["import_id"], payroll_item: { salary_override: "100" } }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(run.payroll_items.find_by!(employee: owner).salary_override).to eq(BigDecimal("8421.13"))
    end

    it "opens and applies a third identical-files revision once when the second was only previewed" do
      source = standing_source
      apply_standing(preview(source))
      second = identical_revision(source, rev: 2, changes: source.change_rows.map { |row| row.merge("hours" => "32") })
      preview(second)
      expect(response).to have_http_status(:ok), response.body
      third = identical_revision(source, rev: 3, changes: source.change_rows.map { |row| row.merge("hours" => "50") })
      data = preview(third)
      expect(response).to have_http_status(:ok), response.body
      reviewed = reviewed_standing_params(data)[:reviewed_changes]
      reviewed.last[:hours] = "50"
      apply_standing(data, reviewed)
      item = run.payroll_items.find_by!(employee: manual_worker)
      expect(item.hours_worked).to eq(50)
      expect(item.wage_rate_hours.sum { |entry| entry["regular_hours"].to_d }).to eq(50)
      expect(second.submission_imports.sole.applied_at).to be_nil
      expect(third.submission_imports.where.not(applied_at: nil).count).to eq(1)
    end

    it "guards pay-run replacement selection even after source disposition and a newer revision" do
      source = standing_source
      first = pay_run_preview(source)
      post "#{url}/apply_import", params: reviewed_standing_params(first).merge(use_submission_id: source.id), as: :json
      expect(response).to have_http_status(:ok), response.body
      second = identical_revision(source, rev: 2, changes: source.change_rows.map { |row| row.merge("skipped" => true) })
      retained_workbook = PayrollImportRecord.find(first["import_id"]).payroll_intake_session.documents.find_by!(source_role: "supplemental_workbook")
      post "#{url}/preview_import", params: { pdf_file: portal_upload("revel.pdf", objects.fetch(source.revel_document.client_document.file_key), "application/pdf"),
        excel_file: portal_upload("downloaded.xlsx", objects.fetch(retained_workbook.storage_reference), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        use_submission_id: second.id }
      expect(response).to have_http_status(:ok), response.body
      data = response.parsed_body
      post "#{url}/resolve_portal_source", params: { submission_id: second.id, reason: "Will review the changes separately" }, as: :json
      expect(response).to have_http_status(:ok), response.body
      apply(data)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Select the client revision")
      identical_revision(source, rev: 3, changes: source.change_rows)
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      patch "#{url}/payroll_items/#{run.payroll_items.find_by!(employee: owner).id}",
        params: { expected_import_id: data["import_id"], payroll_item: { salary_override: "100" } }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(run.payroll_items.find_by!(employee: owner).salary_override).to eq(BigDecimal("8421.13"))
    end

    def corrected_standing(data, changes)
      bytes = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 0, overtime_hours: 0, regular_pay: 0 } ],
        period_start: run.start_date, period_end: run.end_date))
      second = revision(rev: 2, bytes: bytes)
      second.update_columns(change_rows: changes)
      period.transition!("submit", actor: create(:user, company: company, role: "client"), submission: second)
      preview(second, supersedes_package_id: data.dig("source_package", "package_id"), supersession_reason: "Corrected revision")
    end

    it "clears old allocations when corrected Revel hours drop to zero" do
      job = create(:employee_wage_rate, employee: employee, label: "Service", rate: 10, is_primary: true)
      source = standing_source
      changes = source.change_rows + [ { "kind" => "extra_hours", "employee_id" => employee.id,
        "employee_wage_rate_id" => job.id, "wage_rate" => "10.0", "hours" => "5" } ]
      source.update_columns(change_rows: changes)
      data = preview(source)
      reviewed = reviewed_standing_params(data)[:reviewed_changes] + [ { change_index: 2, hours: "5" } ]
      apply_standing(data, reviewed)
      latest = corrected_standing(data, changes)
      apply_standing(latest, reviewed)
      item = run.payroll_items.find_by!(employee: employee)
      expect(item.hours_worked).to eq(5)
      expect(item.wage_rate_hours.sum { |entry| entry["regular_hours"].to_d }).to eq(5)
      expect(item.regular_pay).to eq(50)
    end

    %w[skipped dropped].each do |mode|
      it "removes absent Addison's earlier hours when #{mode}, even with no active proposals" do
        source = standing_source
        data = preview(source)
        apply_standing(data)
        owner_item = run.payroll_items.find_by!(employee: owner)
        owner_item.clear_imported_period_pay_evidence!
        owner_item.save!
        changes = mode == "skipped" ? source.change_rows.map { |row| row.merge("skipped" => true) } : []
        latest = corrected_standing(data, changes)
        removal_text = Array(latest.dig("client_change_prefill", "removals")).join
        apply_standing(latest, [])
        item = run.payroll_items.find_by!(employee: manual_worker)
        expect(item.hours_worked).to eq(0)
        expect(item.wage_rate_hours).to be_empty
        expect(item.custom_columns_data["client_change_evidence"]).to be_nil
        expect(removal_text).to include("68", manual_worker.full_name)
      end
    end

    %w[skipped dropped].each do |mode|
      it "marks #{mode} owner pay missing instead of relabelling an earlier client's pay as manual" do
        source = standing_source
        data = preview(source)
        apply_standing(data)
        latest = corrected_standing(data, mode == "skipped" ? source.change_rows.map { |row| row.merge("skipped" => true) } : [])
        row = latest.dig("preview", "matched").find { |item| item["employee_id"] == owner.id }
        expect(row).to include("period_pay_missing" => true, "current_period_pay" => nil)
        post "#{url}/apply_import", params: { import_id: latest["import_id"], portal_source_id: latest.dig("portal_source", "selection_id") }, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include(owner.full_name)
      end
    end

    def linked_identical_preview(source)
      pdf, workbook = source.submission_documents.order(:position).map do |link|
        portal_upload(link.file_name_snapshot, objects.fetch(link.client_document.file_key), link.client_document.content_type)
      end
      post "#{url}/preview_import", params: { pdf_file: pdf, excel_file: workbook, use_submission_id: source.id }
      response.parsed_body
    end

    %w[portal pay_run].each do |route|
      %w[no_pay excluded fresh undecided restore missing_reason rollback].each do |outcome|
        it "resolves skipped prior owner pay with #{outcome} through #{route} on identical files" do
          source = standing_source
          add_source(source, PayrollImport::MosaSupplementalTemplate.new(run).generate, "changes_workbook", "changes.xlsx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
          apply_standing(preview(source))
          financial_fields = PayrollItem.columns.select { |column| column.type == :decimal }.map(&:name) + %w[wage_rate_hours employment_type import_source]
          original = run.payroll_items.find_by!(employee: owner).attributes.slice(*financial_fields)
          second = identical_revision(source, rev: 2, changes: source.change_rows.map { |row| row.merge("skipped" => true) })
          data = route == "portal" ? preview(second) : linked_identical_preview(second)
          expect(response).to have_http_status(:ok), response.body
          change = (data["client_change_prefill"] || data["pending_change_prefill"]).fetch("rows").find { |row| row["employee_id"] == owner.id }
          expect(change).to include("requires_pay_decision" => true)
          expect(change["saved_period_pay"]).to be_nil
          params = { import_id: data["import_id"], confirm_client_changes: true,
            portal_source_id: data.dig("portal_source", "selection_id"),
            reviewed_changes: [ { change_index: change["change_index"], decision: "no_pay", reason: "Client confirmed no pay this period" } ] }
          params[:use_submission_id] = second.id if route == "pay_run"
          if outcome == "fresh"
            params[:reviewed_changes] = [ { change_index: change["change_index"], amount: "3000" } ]
          elsif outcome == "undecided"
            params[:reviewed_changes] = []
          elsif outcome == "missing_reason"
            params[:reviewed_changes].first[:reason] = " "
          elsif outcome == "excluded"
            params[:reviewed_changes] = []
            params[:rows] = data.dig("preview", "source_rows").map do |row|
              { id: row["id"], disposition: row["employee_id"] == owner.id ? "excluded" : "included",
                disposition_reason: row["employee_id"] == owner.id ? "Client confirmed no pay this period" : nil }
            end
          end
          if outcome == "rollback"
            allow_any_instance_of(PayrollItem).to receive(:calculate!).and_raise(StandardError, "Synthetic calculation failure")
          end
          post "#{url}/apply_import", params: params, as: :json
          if outcome == "rollback"
            expect(response).to have_http_status(:unprocessable_entity)
            expect(run.payroll_items.find_by!(employee: owner).attributes.slice(*financial_fields)).to eq(original)
            expect(run.pay_period_excluded_employees).to be_empty
            expect(PayrollImportRecord.find(data["import_id"]).status).to eq("previewed")
            expect(second.submission_imports.where.not(applied_at: nil)).to be_empty
            next
          end
          if %w[undecided missing_reason].include?(outcome)
            expect(response).to have_http_status(:unprocessable_entity)
            expect(response.parsed_body["error"]).to include(outcome == "undecided" ? "in this review" : "reason")
            expect(run.payroll_items.find_by!(employee: owner).salary_override).to eq(BigDecimal("8421.13"))
            expect(run.pay_period_excluded_employees).to be_empty
            next
          end
          expect(response).to have_http_status(:ok), response.body
          record = PayrollImportRecord.find(data["import_id"])
          decision = record.raw_data.fetch("client_change_decisions").find { |row| row["employee_id"] == owner.id }
          if outcome == "fresh"
            expect(run.payroll_items.find_by!(employee: owner).salary_override).to eq(3000)
            expect(decision).to include("decision" => "apply", "applied_value" => "3000")
          else
            expect(run.payroll_items.find_by(employee: owner)).to be_nil
            exclusion = run.pay_period_excluded_employees.find_by!(employee: owner)
            expect(exclusion).to have_attributes(reason: "Client confirmed no pay this period", excluded_by: staff)
            expect(decision).to include("decision" => "no_pay", "reason" => exclusion.reason, "exclusion_id" => exclusion.id)
            event = PayrollSubmissions::Audit.feed(period).find_by!(action: "payroll_submission_periods#import")
            expect(event.metadata.fetch("client_change_decisions")).to include(include("reason" => exclusion.reason))
            expect(period.status_events.order(:id).last.note).to include("No pay this period", exclusion.reason)
            expect(PayPeriodDefaultRoster.new(run).employee_ids).not_to include(owner.id)
          end
          next unless outcome == "restore"

          third = identical_revision(source, rev: 3, changes: source.change_rows)
          restored = route == "portal" ? preview(third) : linked_identical_preview(third)
          expect(response).to have_http_status(:ok), response.body
          restored_params = reviewed_standing_params(restored).merge(portal_source_id: restored.dig("portal_source", "selection_id"))
          restored_params[:use_submission_id] = third.id if route == "pay_run"
          post "#{url}/apply_import", params: restored_params, as: :json
          expect(response).to have_http_status(:ok), response.body
          expect(run.pay_period_excluded_employees.where(employee: owner)).to be_empty
          expect(run.payroll_items.find_by!(employee: owner).attributes.slice(*original.keys)).to eq(original)
          expect(run.payroll_items.find_by!(employee: manual_worker).hours_worked).to eq(68)
        end
      end
    end

    it "accepts a worksheet edit as the new baseline for a corrected revision" do
      source = standing_source
      data = preview(source)
      apply_standing(data)
      item = run.payroll_items.find_by!(employee: manual_worker)
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      patch "#{url}/payroll_items/#{item.id}", params: { payroll_item: { hours_worked: 2 } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.custom_columns_data["client_change_evidence"]).to be_nil
      latest = corrected_standing(data, source.change_rows)
      expect(latest.dig("client_change_prefill", "rows").last["saved_regular_hours"]).to eq("2.0")
      apply_standing(latest)
      expect(item.reload.hours_worked).to eq(70)
      expect(item.wage_rate_hours.sum { |entry| entry["regular_hours"].to_d }).to eq(70)
    end

    it "retains the client-hours baseline when a worksheet save sends unchanged hours" do
      source = standing_source
      data = preview(source)
      apply_standing(data)
      item = run.payroll_items.find_by!(employee: manual_worker)
      evidence = item.custom_columns_data["client_change_evidence"]
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      patch "#{url}/payroll_items/#{item.id}", params: { payroll_item: { hours_worked: 68, bonus: 10 } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.custom_columns_data["client_change_evidence"]).to eq(evidence)
    end

    it "keeps the client hours apart from a later overtime-only worksheet edit" do
      source = standing_source
      data = preview(source)
      apply_standing(data)
      item = run.payroll_items.find_by!(employee: manual_worker)
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      patch "#{url}/payroll_items/#{item.id}", params: { payroll_item: { overtime_hours: 3 } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.custom_columns_data["client_change_evidence"]).to be_present
      apply_standing(corrected_standing(data, source.change_rows))
      expect(item.reload.hours_worked).to eq(68)
      expect(item.overtime_hours).to eq(3)
      expect(item.wage_rate_hours.sum { |entry| entry["regular_hours"].to_d }).to eq(68)
      expect(item.wage_rate_hours.sum { |entry| entry["overtime_hours"].to_d }).to eq(3)
    end

    it "applies a file-absent worker with several saved jobs on the job the client named" do
      create(:employee_wage_rate, employee: manual_worker, label: "Kitchen", rate: 18)
      source = standing_source
      apply_standing(preview(source))
      item = run.payroll_items.find_by!(employee: manual_worker)
      expect(item.hours_worked).to eq(68)
      expect(item.wage_rate_hours.map { |entry| [ entry["employee_wage_rate_id"], entry["regular_hours"].to_d ] }).to eq([ [ manual_job.id, 68 ] ])
    end

    it "keeps the client hours apart from an overtime edit sent only through job allocations" do
      source = standing_source
      data = preview(source)
      apply_standing(data)
      item = run.payroll_items.find_by!(employee: manual_worker)
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      allocations = item.wage_rate_hours.map { |entry| entry.merge("overtime_hours" => 3.0) }
      patch "#{url}/payroll_items/#{item.id}", params: { payroll_item: { wage_rate_hours: allocations } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.custom_columns_data["client_change_evidence"]).to be_present
      apply_standing(corrected_standing(data, source.change_rows))
      expect(item.reload.hours_worked).to eq(68)
      expect(item.wage_rate_hours.sum { |entry| entry["regular_hours"].to_d }).to eq(68)
      expect(item.wage_rate_hours.sum { |entry| entry["overtime_hours"].to_d }).to eq(3)
    end

    it "keeps each legacy row's own overtime and clears overtime from a dropped bucket" do
      source = standing_source
      apply_standing(preview(source))
      item = run.payroll_items.find_by!(employee: manual_worker)
      legacy = { "label" => "Legacy", "holiday_hours" => 0.0, "pto_hours" => 0.0, "active" => true }
      dropped = { "employee_wage_rate_id" => manual_job.id, "source_bucket_key" => "gone", "label" => "Maintenance", "rate" => 35.0,
        "regular_hours" => 0.0, "overtime_hours" => 5.0, "holiday_hours" => 0.0, "pto_hours" => 0.0, "active" => true }
      evidence = item.custom_columns_data["client_change_evidence"].merge(
        "baseline_allocations" => [ legacy.merge("rate" => 10.0, "regular_hours" => 1.0, "overtime_hours" => 0.0),
          legacy.merge("label" => "Legacy B", "rate" => 20.0, "regular_hours" => 1.0, "overtime_hours" => 0.0), dropped ])
      item.update_columns(custom_columns_data: item.custom_columns_data.merge("client_change_evidence" => evidence,
        "wage_rate_hours" => [ legacy.merge("rate" => 10.0, "regular_hours" => 30.0, "overtime_hours" => 4.0),
          legacy.merge("label" => "Legacy B", "rate" => 20.0, "regular_hours" => 38.0, "overtime_hours" => 2.0) ]))
      Api::V1::Admin::PayrollItemsController.new.send(:sync_client_hours_evidence!, item.reload)
      baseline = item.reload.custom_columns_data.dig("client_change_evidence", "baseline_allocations")
      expect(baseline.map { |entry| [ entry["rate"].to_d, entry["overtime_hours"].to_d ] }).to eq([ [ 10, 4 ], [ 20, 2 ], [ 35, 0 ] ])
    end

    it "keeps each time bucket's own overtime when two buckets share a job rate" do
      source = standing_source
      apply_standing(preview(source))
      item = run.payroll_items.find_by!(employee: manual_worker)
      job = { "employee_wage_rate_id" => manual_job.id, "label" => "Maintenance", "rate" => 35.0, "holiday_hours" => 0.0, "pto_hours" => 0.0, "active" => true }
      evidence = item.custom_columns_data["client_change_evidence"].merge(
        "baseline_allocations" => [ job.merge("source_bucket_key" => "a", "regular_hours" => 1.0, "overtime_hours" => 0.0),
          job.merge("source_bucket_key" => "b", "regular_hours" => 1.0, "overtime_hours" => 0.0) ])
      item.update_columns(custom_columns_data: item.custom_columns_data.merge("client_change_evidence" => evidence,
        "wage_rate_hours" => [ job.merge("source_bucket_key" => "a", "regular_hours" => 35.0, "overtime_hours" => 1.0),
          job.merge("source_bucket_key" => "b", "regular_hours" => 35.0, "overtime_hours" => 2.0) ]))
      Api::V1::Admin::PayrollItemsController.new.send(:sync_client_hours_evidence!, item.reload)
      baseline = item.reload.custom_columns_data.dig("client_change_evidence", "baseline_allocations")
      expect(baseline.map { |entry| [ entry["source_bucket_key"], entry["overtime_hours"].to_d ] }).to eq([ [ "a", 1 ], [ "b", 2 ] ])
    end

    [ { hours_worked: 10 }, { hours_worked: 0, overtime_hours: 3 } ].each do |own|
      it "asks for a job instead of moving a file-absent worker's own hours (#{own}) to the client's job" do
        create(:employee_wage_rate, employee: manual_worker, label: "Kitchen", rate: 18)
        create(:payroll_item, pay_period: run, company: company, employee: manual_worker, pay_rate: 35, **own)
        data = preview(standing_source)
        post "#{url}/apply_import", params: reviewed_standing_params(data).merge(portal_source_id: data.dig("portal_source", "selection_id"),
          force_overwrite: true, confirm_overwrite: true), as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Choose")
        expect(run.payroll_items.find_by!(employee: manual_worker)).to have_attributes(own)
      end
    end

    it "treats regular hours moved between job entries without a saved job as a new baseline" do
      source = standing_source
      data = preview(source)
      apply_standing(data)
      item = run.payroll_items.find_by!(employee: manual_worker)
      legacy = { "label" => "Legacy A", "rate" => 10.0, "regular_hours" => 30.0, "overtime_hours" => 0.0, "holiday_hours" => 0.0, "pto_hours" => 0.0, "active" => true }
      item.update_columns(custom_columns_data: item.custom_columns_data.merge("wage_rate_hours" => [ legacy, legacy.merge("label" => "Legacy B", "rate" => 20.0, "regular_hours" => 38.0) ]))
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      moved = [ legacy.merge("regular_hours" => 25.0), legacy.merge("label" => "Legacy B", "rate" => 20.0, "regular_hours" => 43.0) ]
      patch "#{url}/payroll_items/#{item.id}", params: { payroll_item: { wage_rate_hours: moved } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.hours_worked).to eq(68)
      expect(item.custom_columns_data["client_change_evidence"]).to be_nil
    end

    it "keeps the client hours apart from overtime added in a new job bucket with no regular hours" do
      source = standing_source
      data = preview(source)
      apply_standing(data)
      item = run.payroll_items.find_by!(employee: manual_worker)
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      allocations = item.wage_rate_hours + [ item.wage_rate_hours.first.merge("source_bucket_key" => "staff-ot", "regular_hours" => 0.0, "overtime_hours" => 3.0) ]
      patch "#{url}/payroll_items/#{item.id}", params: { payroll_item: { wage_rate_hours: allocations } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.custom_columns_data["client_change_evidence"]).to be_present
      apply_standing(corrected_standing(data, source.change_rows))
      expect(item.reload.hours_worked).to eq(68)
      expect(item.wage_rate_hours.sum { |entry| entry["regular_hours"].to_d }).to eq(68)
      expect(item.wage_rate_hours.sum { |entry| entry["overtime_hours"].to_d }).to eq(3)
    end

    [ :owner_only, :with_worker ].each do |files|
      it "removes the owner's paycheck on no pay and keeps the exclusion when restored pay is declined (#{files})" do
        owner.update!(first_name: "Mo", last_name: "Owner")
        people = [ { name: "Owner, Mo", regular_hours: 0, regular_pay: 0 } ]
        people << { name: "Example, Avery", regular_hours: 40, regular_pay: 400 } if files == :with_worker
        source = revision(bytes: File.binread(build_revel_pdf(people, period_start: run.start_date, period_end: run.end_date)))
        source.update_columns(change_rows: [ { "kind" => "owner_pay", "employee_id" => owner.id, "amount" => "8421.13" } ])
        add_source(source, PayrollImport::MosaSupplementalTemplate.new(run).generate, "changes_workbook", "changes.xlsx",
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        apply_standing(preview(source), [ { change_index: 0, amount: "8421.13" } ])
        expect(run.payroll_items.find_by!(employee: owner).salary_override).to eq(BigDecimal("8421.13"))

        second = identical_revision(source, rev: 2, changes: source.change_rows.map { |row| row.merge("skipped" => true) })
        data = preview(second)
        expect(response).to have_http_status(:ok), response.body
        change = data.dig("client_change_prefill", "rows").sole
        expect(change).to include("employee_id" => owner.id, "requires_pay_decision" => true)
        apply_standing(data, [ { change_index: change["change_index"], decision: "no_pay", reason: "Owner took no pay" } ])
        expect(run.payroll_items.find_by(employee: owner)).to be_nil
        exclusion = run.pay_period_excluded_employees.find_by!(employee: owner)
        expect(exclusion.reason).to eq("Owner took no pay")
        expect(second.submission_imports.sole.applied_at).to be_present

        third = identical_revision(source, rev: 3, changes: source.change_rows)
        restored = preview(third)
        expect(response).to have_http_status(:ok), response.body
        apply_standing(restored, [ { change_index: 0, decision: "decline", reason: "Keep owner pay off this run" } ])
        expect(run.payroll_items.find_by(employee: owner)).to be_nil
        expect(run.pay_period_excluded_employees.find_by!(employee: owner)).to eq(exclusion)
        expect(third.submission_imports.sole.applied_at).to be_present
        expect(PayrollImportRecord.find(restored["import_id"]).status).to eq("applied")
      end
    end

    %w[several_jobs one_job].each do |jobs|
      it "restores client hours after the pay run worksheet recalculates them (#{jobs})" do
        kitchen = create(:employee_wage_rate, employee: manual_worker, label: "Kitchen", rate: 18, is_primary: true) if jobs == "several_jobs"
        source = standing_source
        add_source(source, PayrollImport::MosaSupplementalTemplate.new(run).generate, "changes_workbook", "changes.xlsx",
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        apply_standing(preview(source))
        item = run.payroll_items.find_by!(employee: manual_worker)
        # The worksheet's Recalculate payload: every saved job, or totals only for one job.
        hours = { regular: 68, overtime: 0 }
        if kitchen
          hours[:wage_rates] = [
            { employee_wage_rate_id: manual_job.id, label: "Maintenance", rate: 35, regular_hours: 68, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: false, active: true },
            { employee_wage_rate_id: kitchen.id, label: "Kitchen", rate: 18, regular_hours: 0, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: true, active: true }
          ]
        end
        post "#{url}/run_payroll", params: { hours: { manual_worker.id.to_s => hours } }, as: :json
        expect(response).to have_http_status(:ok), response.body
        expect(item.reload.hours_worked).to eq(68)
        expect(item.wage_rate_hours).not_to eq(item.custom_columns_data.dig("client_change_evidence", "applied_allocations"))
        second = identical_revision(source, rev: 2, changes: source.change_rows.map { |row| row.merge("skipped" => true) })
        data = preview(second)
        change = data.dig("client_change_prefill", "rows").find { |row| row["employee_id"] == owner.id }
        apply_standing(data, [ { change_index: change["change_index"], decision: "no_pay", reason: "Owner took no pay" } ])
        expect(run.payroll_items.find_by(employee: manual_worker)&.hours_worked.to_d).to eq(0)
        expect(run.payroll_items.find_by(employee: owner)).to be_nil
      end
    end

    it "still refuses to restore when the worksheet moved the client hours to another job" do
      kitchen = create(:employee_wage_rate, employee: manual_worker, label: "Kitchen", rate: 35)
      source = standing_source
      apply_standing(preview(source))
      wage_rates = [
        { employee_wage_rate_id: manual_job.id, label: "Maintenance", rate: 35, regular_hours: 0, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: false, active: true },
        { employee_wage_rate_id: kitchen.id, label: "Kitchen", rate: 35, regular_hours: 68, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: false, active: true }
      ]
      post "#{url}/run_payroll", params: { hours: { manual_worker.id.to_s => { regular: 68, overtime: 0, wage_rates: wage_rates } } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      second = identical_revision(source, rev: 2, changes: source.change_rows.map { |row| row.merge("skipped" => true) })
      data = preview(second)
      change = data.dig("client_change_prefill", "rows").find { |row| row["employee_id"] == owner.id }
      post "#{url}/apply_import", params: { import_id: data["import_id"], confirm_client_changes: true, portal_source_id: data.dig("portal_source", "selection_id"),
        reviewed_changes: [ { change_index: change["change_index"], decision: "no_pay", reason: "Owner took no pay" } ] }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Saved hours changed")
      expect(run.payroll_items.find_by!(employee: manual_worker).wage_rate_hours.find { |entry| entry["employee_wage_rate_id"] == kitchen.id }["regular_hours"]).to eq(68)
    end

    it "explains instead of deleting when the owner's paycheck already has a check record" do
      source = standing_source
      add_source(source, PayrollImport::MosaSupplementalTemplate.new(run).generate, "changes_workbook", "changes.xlsx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
      apply_standing(preview(source))
      item = run.payroll_items.find_by!(employee: owner)
      create(:check_event, payroll_item: item, user: staff, check_number: "1001")
      second = identical_revision(source, rev: 2, changes: source.change_rows.map { |row| row.merge("skipped" => true) })
      data = preview(second)
      change = data.dig("client_change_prefill", "rows").find { |row| row["employee_id"] == owner.id }
      post "#{url}/apply_import", params: { import_id: data["import_id"], confirm_client_changes: true, portal_source_id: data.dig("portal_source", "selection_id"),
        reviewed_changes: [ { change_index: change["change_index"], decision: "no_pay", reason: "Owner took no pay" } ] }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("already has a check, payment or tax record")
      expect(item.reload).to be_present
      expect(run.pay_period_excluded_employees).to be_empty
    end

    it "records staff declines on the import and in review history" do
      source = standing_source
      manual_worker.update!(status: "inactive")
      data = preview(source)
      reviewed = reviewed_standing_params(data)[:reviewed_changes]
      reviewed.last.merge!(decision: "decline", reason: "Not working this period")
      apply_standing(data, reviewed)
      expect(run.payroll_items.find_by(employee: manual_worker)).to be_nil
      record = PayrollImportRecord.find(data["import_id"])
      expect(record.raw_data.fetch("client_change_decisions").last).to include("decision" => "decline", "reason" => "Not working this period")
      event = PayrollSubmissions::Audit.feed(period).find_by!(action: "payroll_submission_periods#import")
      expect(event.metadata.fetch("client_change_decisions").last).to include("reason" => "Not working this period")
    end

    it "keeps legacy total/each instructions on the manual per-person period-pay path" do
      source = revision
      source.update_columns(change_rows: [ { "kind" => "owner_pay", "amount" => "16842.26", "basis" => "total", "employee_ids" => [ owner.id ], "note" => "Both owners" } ])
      data = preview(source)
      expect(response).to have_http_status(:ok), response.body
      expect(data.dig("client_change_prefill", "rows")).to be_empty
      expect(data.dig("client_change_prefill", "manual_review_warnings").join).to include("no split is inferred")
      expect(data.dig("preview", "matched").find { |row| row["employee_id"] == owner.id }).to include("period_pay_missing" => true)
      stub_portal_user(Api::V1::Admin::PayrollItemsController, staff, company)
      post "#{url}/payroll_items", params: { employee_id: owner.id, salary_override: "8421.13", expected_import_id: data.fetch("import_id") }, as: :json
      expect(response).to have_http_status(:created), response.body
      post "#{url}/apply_import", params: { import_id: data.fetch("import_id"), portal_source_id: data.dig("portal_source", "selection_id"), force_overwrite: true }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(run.payroll_items.find_by!(employee: owner).salary_override).to eq(BigDecimal("8421.13"))
    end

    it "rejects a rate changed after preview and a newer portal revision without payroll writes" do
      source = standing_source
      data = preview(source)
      manual_job.update!(rate: 36)
      post "#{url}/apply_import", params: reviewed_standing_params(data).merge(portal_source_id: data.dig("portal_source", "selection_id")), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("changed")
      expect(run.payroll_items).to be_empty
      expect(source.submission_imports.sole.applied_at).to be_nil
      revision(rev: 2)
      post "#{url}/apply_import", params: reviewed_standing_params(data).merge(portal_source_id: data.dig("portal_source", "selection_id")), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(run.payroll_items).to be_empty
    end
  end
end
