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
      visible_to_client: true, scan_status: "clean")
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

  %w[not_scanned pending infected error].each do |scan|
    it "rejects a #{scan} scan" do
      source = revision
      source.revel_document.client_document.update!(scan_status: scan)
      preview(source)
      expect(response).to have_http_status(:unprocessable_entity)
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

end
