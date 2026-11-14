# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Pay-period submissions", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:org) { create(:organization) }
  let(:company) { create(:company, organization: org, payroll_intake_source_types: [ "mosa_revel" ]) }
  let(:other_company) { create(:company, organization: org, payroll_intake_source_types: [ "mosa_revel" ]) }
  let(:client) { create(:user, company: company, organization: org, role: "client", created_at: 1.year.ago) }
  let(:staff) { create(:user, company: company, organization: org, role: "accountant", created_at: 1.year.ago, name: "Dafne Staff") }
  let(:employee) { create(:employee, company: company) }
  let(:foreign_employee) { create(:employee, company: other_company) }
  let!(:schedule) { manual_biweekly_schedule!(company) }
  let!(:pay_period) { create(:pay_period, company: company, start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 20)) }
  let(:ref) { "2026-11-02_2026-11-15" }
  let(:client_base) { "/api/v1/client/payroll_submission_periods" }
  let(:staff_base) { "/api/v1/admin/payroll_submission_periods" }

  before do
    travel_to Time.zone.parse("2026-11-17 02:00:00 UTC") # Nov 17, noon in Guam
    allow(ClientPortalThreadChannel).to receive(:broadcast_thread)
    create(:company_assignment, user: staff, company: company)
    as_client
  end

  after { travel_back }

  def as_client(user = client, target = company)
    stub_portal_user(Api::V1::Client::PayrollSubmissionPeriodsController, user, target)
  end

  def as_staff(user = staff, target = company)
    stub_portal_user(Api::V1::Admin::PayrollSubmissionPeriodsController, user, target)
  end

  def send_package(target_ref = ref, **params)
    post "#{client_base}/#{target_ref}/submissions", params: { revel_payroll: synthetic_pdf, no_changes: !params.key?(:changes), workbook_choice: params[:changes_workbook] ? "attach" : params[:changes_link_url] ? "link" : "none" }.merge(params)
  end

  def data
    response.parsed_body.fetch("data")
  end

  describe "offered periods" do
    it "offers the pay periods Cornerstone created when the schedule has no anchor" do
      create(:pay_period, company: other_company, start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 16), pay_date: Date.new(2026, 11, 20))
      get client_base
      expect(response).to have_http_status(:ok)
      expect(data.map { |row| row["ref"] }).to eq([ ref ])
      expect(data.first).to include("pay_date" => "2026-11-20", "status" => "waiting_for_files", "open_for_files" => true)
      expect(data.first).not_to have_key("pay_period_id")
      expect(response.parsed_body.dig("meta", "derives_from_schedule")).to be(false)
    end

    it "derives periods from the schedule once an anchor date is set" do
      schedule.update!(ends_on: Date.new(2026, 11, 1))
      manual_biweekly_schedule!(company, anchor: Date.new(2026, 10, 19), effective_on: Date.new(2026, 11, 2))
      get client_base
      refs = data.map { |row| row["ref"] }
      expect(refs.first).to eq("2026-11-16_2026-11-29")
      expect(refs).to include(ref)
      expect(data.first["open_for_files"]).to be(false)
      expect(response.parsed_body.dig("meta", "derives_from_schedule")).to be(true)
    end

    it "refuses periods the schedule does not offer and other companies' periods" do
      get "#{client_base}/2026-11-03_2026-11-16"
      expect(response).to have_http_status(:not_found)
      foreign = PayrollSubmissionPeriod.create!(company: other_company, start_date: pay_period.start_date, end_date: pay_period.end_date, source: "pay_period")
      get "#{client_base}/#{foreign.id}"
      expect(response).to have_http_status(:not_found)
      send_package(foreign.id.to_s)
      expect(response).to have_http_status(:not_found)
      expect(foreign.submissions.count).to eq(0)
    end

    it "keeps a period closed for files until it has ended" do
      future = create(:pay_period, company: company, start_date: Date.new(2026, 11, 16), end_date: Date.new(2026, 11, 29), pay_date: Date.new(2026, 12, 4))
      send_package("#{future.start_date}_#{future.end_date}")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("opens for files on Nov 29")
      expect(PayrollSubmissionPeriod.count).to eq(0)
    end
  end

  describe "sending a package" do
    it "saves a complete package as revision 1 without touching payroll or employee records" do
      changes = [
        { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: create(:employee_wage_rate, employee: employee).id, hours: "6.5", note: "Not in Revel" },
        { kind: "owner_pay", employee_id: create(:employee, :salary, company: company, salary_type: "variable").id, amount: "1200" },
        { kind: "paid_leave", employee_id: employee.id, hours: "35" },
        { kind: "new_hire", name: "Synthetic New Hire", starting_wage: "12.50", wage_unit: "hourly", start_date: "2026-11-10" },
        { kind: "wage_change", employee_id: employee.id, new_wage: "13", wage_unit: "hourly" },
        { kind: "deduction", employee_id: employee.id, deduction_action: "continue", description: "Auto insurance", amount: "40" },
        { kind: "direct_deposit_addition", employee_id: employee.id }
      ]
      employee_before = employee.reload.attributes
      expect do
        send_package(changes: changes.to_json, notes: "Thanks!", changes_workbook: synthetic_workbook,
          attachments: [ synthetic_pdf("timesheet.pdf") ], idempotency_key: "send-1")
      end.to change(PayrollSubmission, :count).by(1).and change(ClientDocument, :count).by(3)
        .and change { PortalNotificationEvent.where(event_type: "payroll_submission_sent").count }.by(1)
      expect(response).to have_http_status(:created)
      expect(data).to include("status" => "submitted", "current_revision" => 1, "allowed_actions" => %w[submit message])
      revision = data["submissions"].first
      expect(revision).to include("revision" => 1, "current" => true, "notes" => "Thanks!", "no_changes" => false)
      expect(revision["documents"].map { |d| d["role"] }).to eq(%w[revel_payroll changes_workbook attachment])
      expect(revision["documents"].first).not_to have_key("sha256")
      expect(revision["changes"].map { |c| c["kind"] }).to eq(changes.map { |c| c[:kind] })
      expect(revision["changes"].first).to include("employee_name" => employee.full_name, "hours" => "6.5")
      expect(revision["changes"].second).to include("employee_id" => changes.second[:employee_id], "amount" => "1200.00")
      expect(employee.reload.attributes.except("updated_at")).to eq(employee_before.except("updated_at"))
      expect(pay_period.reload.payroll_items).to be_empty
      period = PayrollSubmissionPeriod.find(data["id"])
      expect(period.pay_period).to eq(pay_period)
      expect(period.status_events.map(&:event)).to eq(%w[submit])
      expect(AuditLog.where(action: "payroll_submissions#create", record_id: period.id).count).to eq(1)
      expect(AuditLogPresenter.new(AuditLog.find_by(action: "payroll_submissions#create")).headline).to eq("#{client.name} sent payroll files for Nov 2–15, 2026 payroll")
    end

    it "records an explicit no-changes package" do
      send_package(no_changes: true)
      expect(response).to have_http_status(:created)
      expect(data["submissions"].first).to include("no_changes" => true, "changes" => [])
      send_package(no_changes: true, changes: [ { kind: "paid_leave", employee_id: employee.id, hours: "8" } ].to_json)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "requires exactly one Revel PDF and rejects non-PDF Revel files" do
      post "#{client_base}/#{ref}/submissions", params: { no_changes: true }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "revel_payroll")).to eq([ "Attach the Revel payroll PDF" ])
      post "#{client_base}/#{ref}/submissions", params: { no_changes: true, revel_payroll: synthetic_workbook("payroll.xlsx") }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "revel_payroll").join).to include("must be a PDF")
      expect(ClientDocument.count).to eq(0)
    end

    it "rejects forged employees, statuses, actors and carried-forward documents" do
      send_package(changes: [ { kind: "paid_leave", employee_id: foreign_employee.id, hours: "8" } ].to_json)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "changes.1").join).to include("choose an employee from this company")

      foreign_doc = create(:client_document, company: other_company)
      send_package(keep_document_ids: [ foreign_doc.id ])
      expect(response).to have_http_status(:unprocessable_entity)

      send_package(status: "paid", submitted_by_id: staff.id, acknowledged_by_id: staff.id, revision: 9)
      expect(response).to have_http_status(:created)
      submission = PayrollSubmission.last
      expect([ submission.revision, submission.submitted_by_id, submission.acknowledged_by_id ]).to eq([ 1, client.id, nil ])
      expect(submission.period.status).to eq("submitted")
    end

    it "replays a retry, refuses a reused key and treats an identical package as a duplicate" do
      pdf_bytes = "%PDF-1.4\n% same bytes\n%%EOF\n"
      upload = -> { portal_upload("payroll.pdf", pdf_bytes, "application/pdf") }
      post "#{client_base}/#{ref}/submissions", params: { workbook_choice: "none", revel_payroll: upload.call, no_changes: true, idempotency_key: "k1" }
      expect(response).to have_http_status(:created)
      expect do
        post "#{client_base}/#{ref}/submissions", params: { workbook_choice: "none", revel_payroll: upload.call, no_changes: true, idempotency_key: "k1" }
      end.not_to change(ClientDocument, :count)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["outcome"]).to eq("replayed")

      post "#{client_base}/#{ref}/submissions", params: { workbook_choice: "none", revel_payroll: upload.call, no_changes: true, notes: "different", idempotency_key: "k1" }
      expect(response).to have_http_status(:conflict)

      expect do
        post "#{client_base}/#{ref}/submissions", params: { workbook_choice: "none", revel_payroll: upload.call, no_changes: true, idempotency_key: "k2" }
      end.not_to change(PayrollSubmission, :count)
      expect(response.parsed_body["outcome"]).to eq("duplicate")
      expect(data["current_revision"]).to eq(1)
    end

    it "replaces the Revel PDF as a new revision and keeps the earlier one visible" do
      send_package(attachments: [ synthetic_pdf("timesheet.pdf") ], no_changes: true)
      first = data["submissions"].first
      first_revel = first["documents"].first.dig("document", "id")
      attachment = first["documents"].last.dig("document", "id")

      send_package(keep_document_ids: [ attachment ], no_changes: true, based_on_revision: 1)
      expect(response).to have_http_status(:created)
      expect(data["submissions"].map { |s| [ s["revision"], s["current"], s["superseded"] ] }).to eq([ [ 2, true, false ], [ 1, false, true ] ])
      current = data["submissions"].first["documents"]
      expect(current.map { |d| d["role"] }).to eq(%w[revel_payroll attachment])
      expect(current.find { |d| d["role"] == "attachment" }.dig("document", "id")).to eq(attachment)
      expect(ClientDocument.find(first_revel)).to be_present
      expect(data["submissions"].last["documents"].first.dig("document", "id")).to eq(first_revel)

      send_package(based_on_revision: 1, no_changes: true)
      expect(response).to have_http_status(:conflict)
    end

    it "requires the base revision for a correction, but still reports an identical resend as a duplicate" do
      send_package(no_changes: true)
      send_package(no_changes: true, notes: "correction without a base")
      expect(response).to have_http_status(:conflict)
      expect(PayrollSubmission.count).to eq(1)
    end

    it "accepts workbook or link independently of no structured changes and carries both source slots forward" do
      send_package(no_changes: true, workbook_choice: "attach", changes_workbook: synthetic_workbook)
      expect(response).to have_http_status(:created), response.body
      first = data["submissions"].first
      ids = first["documents"].map { |doc| doc.dig("document", "id") }
      post "#{client_base}/#{ref}/submissions", params: { no_changes: true, workbook_choice: "attach", keep_document_ids: ids, based_on_revision: 1, notes: "updated" }
      expect(response).to have_http_status(:created), response.body
      expect(data["submissions"].first["documents"].map { |doc| doc.dig("document", "id") }).to eq(ids)
      expect(data["submissions"].first).to include("workbook_choice" => "attach", "no_changes" => true)
      send_package(no_changes: true, workbook_choice: "link", changes_link_url: "https://example.test/sheet", based_on_revision: 2)
      expect(response).to have_http_status(:created), response.body
      expect(data["submissions"].first).to include("workbook_choice" => "link", "no_changes" => true)
    end

    it "requires exactly one satisfied workbook choice" do
      [ {}, { workbook_choice: "attach" }, { workbook_choice: "link" }, { workbook_choice: "bogus" },
        { workbook_choice: "none", changes_workbook: synthetic_workbook },
        { workbook_choice: "none", changes_link_url: "https://example.test/sheet" },
        { workbook_choice: "link", changes_link_url: "http://example.test/sheet" } ].each do |answers|
        post "#{client_base}/#{ref}/submissions", params: { revel_payroll: synthetic_pdf, no_changes: true, **answers }
        expect(response).to have_http_status(:unprocessable_entity), response.body
      end
      expect(PayrollSubmission.count).to eq(0)
    end

    it "requires changes or an explicit no-changes answer independently of workbook evidence" do
      send_package(no_changes: false)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "changes")).to include('List the changes this period or choose "No changes this period"')
      expect(PayrollSubmission.count).to eq(0)
      send_package(no_changes: true)
      expect(response).to have_http_status(:created), response.body
    end

    it "refuses a new Excel attachment even when the old workbook is kept, then accepts a replacement" do
      send_package(changes_workbook: synthetic_workbook)
      ids = data["submissions"].first["documents"].map { |doc| doc.dig("document", "id") }
      post "#{client_base}/#{ref}/submissions", params: { no_changes: true, keep_document_ids: ids, based_on_revision: 1,
        workbook_choice: "attach", attachments: [ synthetic_workbook("corrected.xlsx") ] }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "attachment").join).to include("tips & loans workbook")
      expect(PayrollSubmission.count).to eq(1)
      post "#{client_base}/#{ref}/submissions", params: { no_changes: true, keep_document_ids: [ ids.first ], based_on_revision: 1,
        workbook_choice: "attach", changes_workbook: portal_upload("corrected.xlsx", office_zip(extra: { "correction.txt" => "corrected tips" }), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") }
      expect(response).to have_http_status(:created), response.body
      expect(data["submissions"].first["documents"].map { |doc| doc["file_name"] }).to include("corrected.xlsx")
      expect(data["submissions"].second["documents"].map { |doc| doc.dig("document", "id") }).to eq(ids)
    end

    it "allows Excel supporting material only with an explicit answer when keeping the workbook" do
      send_package(changes_workbook: synthetic_workbook)
      ids = data["submissions"].first["documents"].map { |doc| doc.dig("document", "id") }
      post "#{client_base}/#{ref}/submissions", params: { no_changes: true, keep_document_ids: ids, based_on_revision: 1,
        workbook_choice: "attach", attachments: [ synthetic_workbook("timesheet.xlsx") ], excel_attachments_supporting: true }
      expect(response).to have_http_status(:created), response.body
      expect(data["submissions"].first["documents"].map { |doc| doc["role"] }).to eq(%w[revel_payroll changes_workbook attachment])
    end

    it "authenticates the client before checking its payroll-file capability" do
      allow_any_instance_of(Api::V1::Client::PayrollSubmissionPeriodsController).to receive(:current_user).and_return(nil)
      get client_base
      expect(response).to have_http_status(:forbidden)
      expect(PayrollSubmission.count).to eq(0)
    end

    it "allows non-MoSa clients to read periods but refuses sending files through the API and service" do
      company.update!(payroll_intake_source_types: [])
      send_package(workbook_choice: "none")
      expect(response).to have_http_status(:forbidden)
      get client_base
      expect(response).to have_http_status(:ok)
      get "#{client_base}/#{ref}"
      expect(response).to have_http_status(:ok)
      expect(data["allowed_actions"]).to eq([ "message" ])
      catalog = PayrollSubmissions::Catalog.new(company: company)
      expect do
        PayrollSubmissions::CreateRevision.new(company: company, actor: client, catalog: catalog,
          entry: catalog.resolve(ref), params: { workbook_choice: "none", revel_payroll: synthetic_pdf }).call
      end.to raise_error(PayrollSubmissions::FileSet::Invalid, /not enabled/)
      expect(PayrollSubmission.count).to eq(0)
    end

    it "lets a non-MoSa client message and approve a posted draft without a submission" do
      company.update!(payroll_intake_source_types: [])
      as_staff
      post "#{staff_base}/#{ref}/drafts", params: { paycheck_pdf: synthetic_pdf("fixed-pay-draft.pdf"), post: true }
      expect(response).to have_http_status(:created), response.body
      period_id = data["id"]
      draft_id = data["drafts"].first["id"]
      as_client
      get "#{client_base}/#{period_id}"
      expect(response).to have_http_status(:ok)
      expect(data["submissions"]).to be_empty
      expect(data["drafts"].first["id"]).to eq(draft_id)
      expect(data["allowed_actions"]).to contain_exactly("approve", "request_changes", "message")
      post "#{client_base}/#{period_id}/messages", params: { body: "Checking this draft", idempotency_key: "fixed-message" }
      expect(response).to have_http_status(:created), response.body
      expect(PayrollSubmissionPeriod.find(period_id).client_portal_thread.messages.last.body).to eq("Checking this draft")
      post "#{client_base}/#{period_id}/decision", params: { decision: "approve", draft_id: draft_id }
      expect(response).to have_http_status(:ok), response.body
      expect(data["status"]).to eq("approved")
    end

    it "still serializes legacy revisions without inventing a no-tips declaration" do
      send_package(workbook_choice: "none")
      PayrollSubmission.last.update_columns(workbook_choice: nil, no_changes: false)
      get "#{client_base}/#{data['id']}"
      expect(response).to have_http_status(:ok)
      expect(data["submissions"].first).to include("workbook_choice" => nil, "no_changes" => false)
    end

    it "removes every stored object when an upload fails part-way through a package" do
      calls = 0
      written = []
      allow_any_instance_of(R2StorageService).to receive(:upload).and_wrap_original do |original, key, *args, **opts|
        calls += 1
        original.call(key, *args, **opts)
        written << key
        raise R2StorageService::UploadError, "connection reset after write" if calls == 2
      end
      send_package(no_changes: true, attachments: [ synthetic_pdf("timesheet.pdf") ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(written.size).to eq(2)
      expect(written.map { |key| R2StorageService.new.download(key) }).to all(be_nil)
      expect([ ClientDocument.count, PayrollSubmission.count ]).to eq([ 0, 0 ])
    end

    it "keeps submitted files as retained evidence when the client deletes them from the library" do
      send_package(no_changes: true)
      document = ClientDocument.last
      allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_user) { User.find(client.id) }
      allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_company_id).and_return(company.id)
      delete "/api/v1/client/documents/#{document.id}"
      expect(response).to have_http_status(:ok)
      expect(document.reload).to be_archived
    end

    it "rolls back the revision, documents and stored files when the audit write fails" do
      uploaded = []
      allow_any_instance_of(R2StorageService).to receive(:upload).and_wrap_original { |m, key, *args, **opts| uploaded << key; m.call(key, *args, **opts) }
      allow(PayrollSubmissions::Audit).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit unavailable")
      expect do
        send_package(no_changes: true)
      rescue ActiveRecord::StatementInvalid
        nil
      end.not_to change { [ PayrollSubmission.count, ClientDocument.count, PayrollSubmissionStatusEvent.count, PortalNotificationEvent.count ] }
      expect(uploaded).not_to be_empty
      expect(uploaded.map { |key| R2StorageService.new.download(key) }).to all(be_nil)
    end
  end

  describe "staff review" do
    before do
      send_package(no_changes: true)
      as_staff
    end

    let(:period) { PayrollSubmissionPeriod.last }

    it "lists the period for staff with the linked pay run, and acknowledges the exact revision" do
      get staff_base
      expect(data.first).to include("ref" => period.id.to_s, "pay_period_id" => pay_period.id, "unread" => true)

      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      expect(response).to have_http_status(:ok)
      expect(data["status"]).to eq("received")
      expect(data["submissions"].first).to include("acknowledged_by_name" => "Dafne Staff")
      expect(data["history"].last).to include("event" => "acknowledge", "actor_name" => "Dafne Staff", "actor_audience" => "staff")
      expect(PortalNotificationEvent.where(event_type: "payroll_submission_acknowledged").count).to eq(1)

      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      expect(response).to have_http_status(:ok)
      expect(period.status_events.count).to eq(2)
    end

    it "refuses a stale or forged revision when acknowledging" do
      first = period.submissions.first
      as_client
      send_package(no_changes: true, notes: "corrected", based_on_revision: 1)
      as_staff
      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: first.id }
      expect(response).to have_http_status(:conflict)
      other = PayrollSubmissionPeriod.create!(company: other_company, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 14), source: "pay_period")
      post "#{staff_base}/#{other.id}/acknowledge", params: { submission_id: first.id }
      expect(response).to have_http_status(:not_found)
    end

    it "marks only the client update that was displayed as seen" do
      shown = period.latest_client_event
      get "#{staff_base}/#{period.id}"
      expect(data["latest_client_event_id"]).to eq(shown.id)
      as_client
      send_package(no_changes: true, notes: "arrived while staff had the page open", based_on_revision: 1)
      as_staff
      post "#{staff_base}/#{period.id}/seen", params: { foreground: true, displayed_event_id: shown.id }
      expect(response).to have_http_status(:no_content)
      get staff_base
      expect(data.first["unread"]).to be(true)
      post "#{staff_base}/#{period.id}/seen", params: { foreground: true, displayed_event_id: period.latest_client_event.id }
      get staff_base
      expect(data.first["unread"]).to be(false)
      post "#{staff_base}/#{period.id}/seen", params: { foreground: true, displayed_event_id: shown.id }
      expect(period.read_receipts.find_by(user: staff).last_seen_event_id).to eq(period.latest_client_event.id)

      post "#{staff_base}/#{period.id}/seen", params: { displayed_event_id: shown.id }
      expect(response).to have_http_status(:unprocessable_entity)
      other = PayrollSubmissionPeriod.create!(company: company, start_date: Date.new(2026, 1, 5), end_date: Date.new(2026, 1, 18), source: "pay_period")
      other_event = other.with_lock { other.transition!("submit", actor: client) }
      post "#{staff_base}/#{period.id}/seen", params: { foreground: true, displayed_event_id: other_event.id }
      expect(response).to have_http_status(:not_found)
    end

    it "replays a draft retry and refuses a reused key with a different draft" do
      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      bytes = "%PDF-1.4\n% draft bytes\n%%EOF\n"
      draft_pdf = -> { portal_upload("paychecks.pdf", bytes, "application/pdf") }
      post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: draft_pdf.call, note: "first", idempotency_key: "d1" }
      expect(response).to have_http_status(:created)
      expect do
        post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: draft_pdf.call, note: "first", idempotency_key: "d1" }
      end.not_to change(ClientDocument, :count)
      expect(period.drafts.count).to eq(1)
      expect do
        post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: draft_pdf.call, note: "corrected note", idempotency_key: "d1" }
      end.not_to change(ClientDocument, :count)
      expect(response).to have_http_status(:conflict)
      post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: draft_pdf.call, note: "first", post: false, idempotency_key: "d1" }
      expect(response).to have_http_status(:conflict)
      expect(period.drafts.count).to eq(1)
    end

    it "removes both stored draft files when the second upload fails" do
      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      calls = 0
      written = []
      allow_any_instance_of(R2StorageService).to receive(:upload).and_wrap_original do |original, key, *args, **opts|
        calls += 1
        original.call(key, *args, **opts)
        written << key
        raise Timeout::Error, "read timeout after the object was stored" if calls == 2
      end
      expect do
        post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: synthetic_pdf("p.pdf"), direct_deposit_pdf: synthetic_pdf("d.pdf") }
      rescue Timeout::Error
        nil
      end.not_to change { [ ClientDocument.count, PayrollSubmissionDraft.count ] }
      expect(written.size).to eq(2)
      expect(written.map { |key| R2StorageService.new.download(key) }).to all(be_nil)
    end

    it "keeps a posted draft's files available to the client instead of archiving them" do
      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: synthetic_pdf("posted.pdf") }
      posted = period.drafts.first.paycheck_document
      post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: synthetic_pdf("hidden.pdf"), post: false }
      hidden = period.drafts.first.paycheck_document
      allow_any_instance_of(Api::V1::Admin::ClientDocumentsController).to receive(:current_user) { User.find(staff.id) }
      allow_any_instance_of(Api::V1::Admin::ClientDocumentsController).to receive(:current_company_id).and_return(company.id)

      delete "/api/v1/admin/client_documents/#{posted.id}"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("shared with the client for review")
      expect(posted.reload).not_to be_archived

      as_client
      allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_user) { User.find(client.id) }
      allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_company_id).and_return(company.id)
      get "/api/v1/client/documents/#{posted.id}/download"
      expect(response).to have_http_status(:ok)

      delete "/api/v1/admin/client_documents/#{hidden.id}"
      expect(response).to have_http_status(:ok)
      expect(hidden.reload).to be_archived
    end

    it "keeps an unposted draft staff-only, then posts it for the client" do
      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: synthetic_pdf("MHI paychecks.pdf"), post: false, note: "Internal check" }
      expect(response).to have_http_status(:created)
      draft = period.drafts.first
      expect(draft).not_to be_posted
      expect(draft.paycheck_document.visible_to_client).to be(false)
      expect(data["status"]).to eq("received")

      as_client
      get "#{client_base}/#{period.id}"
      expect(data["drafts"]).to eq([])
      expect(response.body).not_to include("Internal check")
      expect(response.body).not_to include("MHI paychecks")
      get "#{client_base}/#{period.id}/activity"
      expect(response.parsed_body["data"].map { |e| e["action"] }).not_to include("payroll_submission_drafts#create")
      allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_user) { User.find(client.id) }
      allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_company_id).and_return(company.id)
      get "/api/v1/client/documents/#{draft.paycheck_document_id}/download"
      expect(response).to have_http_status(:not_found)

      as_staff
      post "#{staff_base}/#{period.id}/drafts/#{draft.id}/post"
      expect(response).to have_http_status(:ok)
      expect(data["status"]).to eq("draft_ready")
      expect(draft.reload.paycheck_document.visible_to_client).to be(true)
      expect(PortalNotificationEvent.where(event_type: "payroll_draft_posted").count).to eq(1)

      as_client
      get "#{client_base}/#{period.id}"
      expect(data["drafts"].first).to include("id" => draft.id, "current" => true)
      expect(data["drafts"].first).not_to have_key("created_by_name")
      expect(data["allowed_actions"]).to include("approve", "request_changes")
    end

    it "lets the client approve or request a change on the current draft only" do
      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: synthetic_pdf, direct_deposit_pdf: synthetic_pdf("dd.pdf") }
      first_draft = period.drafts.first

      as_client
      post "#{client_base}/#{period.id}/decision", params: { decision: "request_changes", draft_id: first_draft.id }
      expect(response).to have_http_status(:unprocessable_entity)
      post "#{client_base}/#{period.id}/decision", params: { decision: "request_changes", draft_id: first_draft.id, note: "Add 2 hours for Sam" }
      expect(response).to have_http_status(:ok)
      expect(data["status"]).to eq("changes_requested")
      thread = period.reload.client_portal_thread
      expect(thread.messages.last).to have_attributes(body: "Add 2 hours for Sam", author_id: client.id)
      expect(PortalNotificationEvent.where(event_type: "payroll_draft_decided").count).to eq(1)

      as_staff
      post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: synthetic_pdf }
      second_draft = period.drafts.first

      as_client
      post "#{client_base}/#{period.id}/decision", params: { decision: "approve", draft_id: first_draft.id }
      expect(response).to have_http_status(:not_found)
      post "#{client_base}/#{period.id}/decision", params: { decision: "approve", draft_id: second_draft.id }
      expect(response).to have_http_status(:ok)
      expect(data["status"]).to eq("approved")
      expect(data["drafts"].map { |d| [ d["revision"], d["current"], d["superseded"] ] }).to eq([ [ 2, true, false ], [ 1, false, true ] ])
      post "#{client_base}/#{period.id}/decision", params: { decision: "approve", draft_id: second_draft.id }
      expect(response).to have_http_status(:ok)
      expect(period.status_events.where(event: "approve").count).to eq(1)

      as_staff
      post "#{staff_base}/#{period.id}/mark_paid"
      expect(data["status"]).to eq("paid")
      as_client
      send_package(no_changes: true, notes: "late")
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "enforces per-role transitions" do
      post "#{staff_base}/#{period.id}/mark_paid"
      expect(response).to have_http_status(:unprocessable_entity)
      post "#{staff_base}/#{period.id}/drafts", params: { paycheck_pdf: synthetic_pdf }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Confirm receipt")

      as_client
      post "#{client_base}/#{period.id}/decision", params: { decision: "approve", draft_id: 0 }
      expect(response).to have_http_status(:not_found)
      as_staff(client)
      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      expect(response).to have_http_status(:forbidden)

      catalog = PayrollSubmissions::Catalog.new(company: company)
      actions = PayrollSubmissions::Actions.new(company: company, actor: client, catalog: catalog)
      expect { actions.mark_paid!(period) }.to raise_error(PayrollSubmissionPeriod::TransitionError, /Only Cornerstone staff/)
      staff_actions = PayrollSubmissions::Actions.new(company: company, actor: staff, catalog: catalog)
      expect { period.with_lock { period.transition!("approve", actor: staff) } }.to raise_error(PayrollSubmissionPeriod::TransitionError, /Only the client/)
      expect { staff_actions.start_review!(period) }.to raise_error(PayrollSubmissionPeriod::TransitionError)
      expect(period.reload.status).to eq("submitted")
    end

    it "rolls back an acknowledgement when its audit write fails" do
      allow(PayrollSubmissions::Audit).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit unavailable")
      expect do
        post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      rescue ActiveRecord::StatementInvalid
        nil
      end.not_to change { [ period.reload.status, period.status_events.count, period.submissions.first.acknowledged_at ] }
    end

    it "keeps period questions in one conversation linked to the period" do
      post "#{staff_base}/#{period.id}/messages", params: { body: "Split of the auto insurance?", idempotency_key: "q1" }
      expect(response).to have_http_status(:created)
      thread_id = response.parsed_body["thread_id"]
      post "#{staff_base}/#{period.id}/messages", params: { body: "Split of the auto insurance?", idempotency_key: "q1" }
      expect(response).to have_http_status(:ok)
      as_client
      post "#{client_base}/#{period.id}/messages", params: { body: "Yes, they continue." }
      expect(response.parsed_body["thread_id"]).to eq(thread_id)
      expect(period.reload.client_portal_thread.messages.count).to eq(2)
      get "#{client_base}/#{period.id}"
      expect(data["thread_id"]).to eq(thread_id)
    end
  end

  describe "Client Inbox" do
    before do
      allow_any_instance_of(Api::V1::Admin::ClientInboxController).to receive(:current_user) { User.find(staff.id) }
    end

    it "shows new submissions and approvals as waiting staff work, without listing the files separately" do
      send_package(no_changes: true, attachments: [ synthetic_pdf("timesheet.pdf") ])
      period = PayrollSubmissionPeriod.last
      get "/api/v1/admin/client_inbox", params: { status: "all" }
      rows = response.parsed_body["data"]
      expect(rows.map { |r| r["kind"] }).to eq([ "payroll_submission" ])
      expect(rows.first).to include("id" => period.id, "title" => "Payroll Nov 2–15, 2026", "waiting" => true, "unread" => true, "sender_name" => client.name)

      as_staff
      post "#{staff_base}/#{period.id}/seen", params: { foreground: true, displayed_event_id: period.latest_client_event.id }
      expect(response).to have_http_status(:no_content)
      get "/api/v1/admin/client_inbox", params: { status: "all" }
      expect(response.parsed_body["data"].first).to include("unread" => false, "waiting" => true)
      post "#{staff_base}/#{period.id}/acknowledge", params: { submission_id: period.submissions.first.id }
      get "/api/v1/admin/client_inbox/counts"
      expect(response.parsed_body.dig("data", "waiting_payroll")).to eq(0)
    end
  end
  describe "every-period defaults" do
    let!(:owner) { create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0) }
    let!(:default) { PayrollStandingChange.create!(company: company, employee: owner, kind: "owner_pay") }

    it "offers blank per-person defaults, refuses omission, and records a filled default as a change" do
      get "#{client_base}/#{ref}"
      expect(response).to have_http_status(:ok)
      expect(data.fetch("standing_changes").sole).to include("standing_change_id" => default.id, "employee_id" => owner.id)
      expect(data.fetch("standing_changes").sole).not_to have_key("amount")
      send_package(no_changes: true)
      expect(response).to have_http_status(:unprocessable_entity)
      send_package(changes: [ { kind: "owner_pay", standing_change_id: default.id, employee_id: owner.id, amount: "8421.13" } ].to_json)
      expect(response).to have_http_status(:created), response.body
      expect(data.fetch("submissions").first.fetch("changes").sole).to include("amount" => "8421.13")
      expect(PayrollItem.count).to eq(0)
    end

    it "records explicit skips alongside No changes and rejects using both No changes and an amount" do
      row = { kind: "owner_pay", standing_change_id: default.id, employee_id: owner.id }
      send_package(no_changes: true, changes: [ row.merge(amount: "1") ].to_json)
      expect(response).to have_http_status(:unprocessable_entity)
      send_package(no_changes: true, changes: [ row.merge(skipped: true) ].to_json)
      expect(response).to have_http_status(:created), response.body
      expect(data.fetch("submissions").first).to include("no_changes" => true, "changes" => [ include("skipped" => true) ])
      expect(default.reload).to be_active
    end
  end
end
