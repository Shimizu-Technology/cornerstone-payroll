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
end
