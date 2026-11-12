# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Portal file requests", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:org) { create(:organization) }
  let(:company) { create(:company, organization: org) }
  let(:other_company) { create(:company, organization: org) }
  let(:client) { create(:user, company: company, organization: org, role: "client", created_at: 1.year.ago) }
  let(:staff) { create(:user, company: company, organization: org, role: "accountant", created_at: 1.year.ago, name: "Dafne Staff") }
  let(:employee) { create(:employee, company: company, first_name: "Riley", last_name: "Cook") }
  let!(:schedule) { manual_biweekly_schedule!(company) }
  let!(:pay_period) { create(:pay_period, company: company, start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 20)) }
  let(:period_ref) { "2026-11-02_2026-11-15" }

  before do
    travel_to Time.zone.parse("2026-11-17 02:00:00 UTC")
    allow(ClientPortalThreadChannel).to receive(:broadcast_thread)
    create(:company_assignment, user: staff, company: company)
    create(:company_assignment, user: client, company: company)
    PortalNotificationRecipient.create!(company: company, user: staff)
    as_staff
  end

  after { travel_back }

  def as_staff
    [ Api::V1::Admin::PortalFileRequestsController, Api::V1::Admin::PortalThreadsController, Api::V1::Admin::PayrollSubmissionPeriodsController ].each do |controller|
      stub_portal_user(controller, staff, company)
    end
  end

  def as_client(user = client, target = company)
    [ Api::V1::Client::PortalFileRequestsController, Api::V1::Client::PortalThreadsController, Api::V1::Client::PayrollSubmissionPeriodsController ].each do |controller|
      stub_portal_user(controller, user, target)
    end
  end

  def request_file(**params)
    post "/api/v1/admin/portal_file_requests", params: { title: "Riley's timesheet", category: "payroll_source",
      employee_id: employee.id, payroll_submission_period_ref: period_ref, due_on: "2026-11-18",
      body: "Please send Riley's paper timesheet.", idempotency_key: "request-1" }.merge(params)
  end

  def client_file(**attrs)
    create(:client_document, { company: company, uploaded_by: client, title: "Riley timesheet.pdf", category: "payroll_source" }.merge(attrs))
  end

  def respond_with(request_id, documents, key: SecureRandom.uuid, body: "Here it is")
    post "/api/v1/client/portal_file_requests/#{request_id}/respond", params: { body: body, document_ids: documents.map(&:id), idempotency_key: key }
  end

  def data
    response.parsed_body.fetch("data")
  end

  it "runs request, response, ask again and accept, with both sides seeing each state" do
    request_file
    expect(response).to have_http_status(:created)
    request = PortalFileRequest.find(data.fetch("id"))
    period = PayrollSubmissionPeriod.find_by!(company_id: company.id, start_date: Date.new(2026, 11, 2))
    expect(request).to have_attributes(status: "requested", employee_id: employee.id, payroll_submission_period_id: period.id,
      due_on: Date.new(2026, 11, 18), client_portal_thread_id: period.client_portal_thread_id)
    expect(response.parsed_body.dig("thread", "messages", 0)).to include("kind" => "file_request", "body" => "Please send Riley's paper timesheet.")
    expect(response.parsed_body.dig("thread", "messages", 0, "file_request")).to include("status" => "requested", "employee_name" => "Riley Cook",
      "payroll_submission_period_label" => period.label)
    expect(PortalNotificationEvent.find_by!(event_type: "file_requested").metadata).to include("file_request_id" => request.id)
    expect(PortalNotificationEvent.where(event_type: "staff_reply")).to be_empty

    # A retried request returns the saved one.
    expect { request_file }.not_to change(PortalFileRequest, :count)
    expect(response).to have_http_status(:ok)

    as_client
    get "/api/v1/client/portal_threads/#{request.client_portal_thread_id}"
    expect(data.fetch("open_file_request_count")).to eq(1)
    expect(data.dig("messages", 0, "file_request", "status_label")).to eq("Waiting for the file")

    first = client_file
    respond_with(request.id, [ first ], key: "answer-1")
    expect(response).to have_http_status(:created)
    first_answer = response.parsed_body.dig("message", "id")
    expect(response.parsed_body.dig("message", "documents", 0, "id")).to eq(first.id)
    expect(request.reload).to have_attributes(status: "responded", last_response_message_id: first_answer, responded_by_id: client.id)
    expect(PortalNotificationEvent.find_by!(event_type: "file_request_responded").metadata).to include("attachment_count" => 1)
    expect(PortalNotificationEvent.where(event_type: "client_message")).to be_empty
    respond_with(request.id, [ first ], key: "answer-1")
    expect(response).to have_http_status(:ok)
    expect(request.messages.where(kind: "file_response").count).to eq(1)

    as_staff
    post "/api/v1/admin/portal_file_requests/#{request.id}/ask_again", params: { body: "This is October's. Please send November.", response_message_id: first_answer }
    expect(response).to have_http_status(:created)
    expect(request.reload.status).to eq("requested")

    as_client
    second = client_file(title: "Riley November.pdf")
    respond_with(request.id, [ second ])
    second_answer = response.parsed_body.dig("message", "id")

    as_staff
    post "/api/v1/admin/portal_file_requests/#{request.id}/accept", params: { response_message_id: first_answer }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to eq("The client sent a newer file. Review it first.")
    post "/api/v1/admin/portal_file_requests/#{request.id}/accept", params: { response_message_id: second_answer, body: "Got it, thanks." }
    expect(response).to have_http_status(:created)
    expect(request.reload).to have_attributes(status: "accepted", resolved_by_id: staff.id)
    expect(data).to include("status_label" => "Accepted")

    as_client
    respond_with(request.id, [ client_file ])
    expect(response).to have_http_status(:conflict)
    get "/api/v1/client/portal_threads/#{request.client_portal_thread_id}"
    expect(data.fetch("messages").map { |message| message["kind"] }).to eq(%w[file_request file_response file_request_asked_again file_response file_request_accepted])
    expect(data.fetch("open_file_request_count")).to eq(0)
    expect(AuditLog.where(company_id: company.id, action: %w[portal_file_requests#create portal_file_requests#respond portal_file_requests#ask_again portal_file_requests#accept])
      .order(:id).pluck(:action)).to eq(%w[portal_file_requests#create portal_file_requests#respond portal_file_requests#ask_again portal_file_requests#respond portal_file_requests#accept])
  end

  it "keeps an unresolved request from marking the pay period complete" do
    period = PayrollSubmissions::Catalog.new(company: company).then { |catalog| catalog.materialize!(catalog.resolve(period_ref)) }
    period.update!(status: "draft_ready")
    request_file(idempotency_key: "blocking")
    request_id = data.fetch("id")

    get "/api/v1/admin/payroll_submission_periods/#{period.id}"
    expect(data.fetch("allowed_actions")).not_to include("mark_paid")
    expect(data.fetch("file_requests").map { |row| row["status"] }).to eq([ "requested" ])

    post "/api/v1/admin/payroll_submission_periods/#{period.id}/mark_paid"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("A requested file is still outstanding. Accept or withdraw it first.")
    expect(period.reload.status).to eq("draft_ready")

    # A response is not acceptance, so the period still cannot be completed.
    as_client
    get "/api/v1/client/payroll_submission_periods/#{period.id}"
    expect(data.fetch("file_requests").first).to include("title" => "Riley's timesheet", "status" => "requested")
    respond_with(request_id, [ client_file ])
    as_staff
    post "/api/v1/admin/payroll_submission_periods/#{period.id}/mark_paid"
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/v1/admin/portal_file_requests/#{request_id}/withdraw", params: { body: "Found it in the Revel export." }
    expect(response).to have_http_status(:created)
    post "/api/v1/admin/payroll_submission_periods/#{period.id}/mark_paid"
    expect(response).to have_http_status(:ok)
    expect(period.reload.status).to eq("paid")
  end

  it "refuses a new request on a paid pay period" do
    period = PayrollSubmissions::Catalog.new(company: company).then { |catalog| catalog.materialize!(catalog.resolve(period_ref)) }
    period.update!(status: "paid")
    expect { request_file(idempotency_key: "paid") }.not_to change(PortalFileRequest, :count)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to eq("This pay period is paid, so it no longer takes file requests")

    # Also when staff start it from the period's own conversation.
    thread = create(:client_portal_thread, company: company, created_by: staff)
    period.update!(client_portal_thread: thread)
    expect { request_file(payroll_submission_period_ref: nil, thread_id: thread.id, idempotency_key: "paid-thread") }.not_to change(PortalFileRequest, :count)
    expect(response).to have_http_status(:conflict)
  end

  it "ties a request made in a period's conversation to that period, so it blocks Mark paid" do
    period = PayrollSubmissions::Catalog.new(company: company).then { |catalog| catalog.materialize!(catalog.resolve(period_ref)) }
    thread = create(:client_portal_thread, company: company, created_by: staff, subject: "Payroll #{period.label}")
    period.update!(client_portal_thread: thread, status: "draft_ready")
    request_file(payroll_submission_period_ref: nil, thread_id: thread.id, idempotency_key: "from-thread")
    expect(response).to have_http_status(:created)
    expect(PortalFileRequest.find(data.fetch("id")).payroll_submission_period_id).to eq(period.id)

    post "/api/v1/admin/payroll_submission_periods/#{period.id}/mark_paid"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(period.reload.status).to eq("draft_ready")
  end

  it "rechecks the sent file under lock before accepting it" do
    request_file
    request_id = data.fetch("id")
    file = client_file
    as_client
    respond_with(request_id, [ file ])
    answer = response.parsed_body.dig("message", "id")

    as_staff
    file.update_columns(scan_status: "infected")
    post "/api/v1/admin/portal_file_requests/#{request_id}/accept", params: { response_message_id: answer }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to eq("The file that was sent did not pass the safety check. Ask the client again instead.")
    expect(PortalFileRequest.find(request_id).status).to eq("responded")

    file.update_columns(scan_status: "clean", archived_at: Time.current, archived_by_id: staff.id)
    post "/api/v1/admin/portal_file_requests/#{request_id}/accept", params: { response_message_id: answer }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to eq("The file that was sent is no longer available. Ask the client again instead.")
    expect(PortalFileRequest.find(request_id).messages.where(kind: "file_request_accepted")).to be_empty

    file.update_columns(archived_at: nil, archived_by_id: nil)
    post "/api/v1/admin/portal_file_requests/#{request_id}/accept", params: { response_message_id: answer }
    expect(response).to have_http_status(:created)
  end

  it "keeps several files of one response in order" do
    request_file
    request_id = data.fetch("id")
    first = client_file(title: "Week 1.pdf")
    second = client_file(title: "Week 2.pdf")
    as_client
    respond_with(request_id, [ second, first ])
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("message", "documents").map { |row| row["id"] }).to eq([ second.id, first.id ])
    message = ClientPortalMessage.find(response.parsed_body.dig("message", "id"))
    expect(message.attachments.pluck(:client_document_id, :position)).to eq([ [ second.id, 0 ], [ first.id, 1 ] ])
    expect(PortalNotificationEvent.where(event_type: "file_request_responded").sole.metadata).to include("attachment_count" => 2)
  end

  it "posts a request without a period in the chosen conversation, or in a new one, and reopens it if resolved" do
    thread = create(:client_portal_thread, company: company, created_by: client, status: "resolved", resolved_at: 1.day.ago, resolved_by: staff)
    request_file(payroll_submission_period_ref: nil, employee_id: nil, thread_id: thread.id, idempotency_key: "in-thread")
    expect(response).to have_http_status(:created)
    expect(data.fetch("thread_id")).to eq(thread.id)
    expect(thread.reload.status).to eq("open")

    request_file(payroll_submission_period_ref: nil, title: "Signed W-4 for Riley", category: "employee_onboarding", idempotency_key: "new-thread")
    expect(response.parsed_body.dig("thread", "subject")).to eq("File request: Signed W-4 for Riley")
  end

  it "refuses another company's employee, period, conversation or request" do
    foreign_employee = create(:employee, company: other_company)
    foreign_thread = create(:client_portal_thread, company: other_company)
    request_file(employee_id: foreign_employee.id)
    expect(response).to have_http_status(:not_found)
    request_file(thread_id: foreign_thread.id, payroll_submission_period_ref: nil)
    expect(response).to have_http_status(:not_found)
    request_file(payroll_submission_period_ref: "2025-01-01_2025-01-14")
    expect(response).to have_http_status(:not_found)
    expect(PortalFileRequest.count).to eq(0)

    request_file
    request_id = data.fetch("id")
    other_client = create(:user, company: other_company, organization: org, role: "client")
    as_client(other_client, other_company)
    respond_with(request_id, [ create(:client_document, company: other_company, uploaded_by: other_client) ])
    expect(response).to have_http_status(:not_found)
    expect(PortalFileRequest.find(request_id).status).to eq("requested")
  end

  it "requires a file the client can see in the response" do
    request_file
    request_id = data.fetch("id")
    as_client
    respond_with(request_id, [])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Attach the requested file")
    hidden = create(:client_document, company: company, uploaded_by: staff, visible_to_client: false, shared_by_staff: true)
    respond_with(request_id, [ hidden ])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(PortalFileRequest.find(request_id).status).to eq("requested")
  end

  it "lists requests and responses in the Client Inbox without a duplicate conversation row" do
    stub_inbox = ->(user) { allow_any_instance_of(Api::V1::Admin::ClientInboxController).to receive(:current_user) { User.find(user.id) } }
    request_file(payroll_submission_period_ref: nil)
    request = PortalFileRequest.find(data.fetch("id"))
    stub_inbox.call(staff)

    get "/api/v1/admin/client_inbox", params: { status: "all", kind: "file_request" }
    row = response.parsed_body.fetch("data").sole
    expect(row).to include("kind" => "file_request", "title" => "File request: Riley's timesheet", "waiting" => false,
      "unread" => false, "state" => "requested", "thread_id" => request.client_portal_thread_id)

    as_client
    # Uploaded in the request's composer, so the request row represents it.
    respond_with(request.id, [ client_file(uploaded_for_message: true) ])
    get "/api/v1/admin/client_inbox", params: { status: "waiting" }
    rows = response.parsed_body.fetch("data")
    expect(rows.map { |item| item["kind"] }).to eq([ "file_request" ])
    expect(rows.first).to include("waiting" => true, "unread" => true, "sender_name" => client.name, "state_label" => "File sent, waiting for Cornerstone")
    get "/api/v1/admin/client_inbox/counts"
    expect(response.parsed_body.fetch("data")).to include("waiting_file_requests" => 1, "unread_documents" => 0)

    # Showing the conversation clears the unread mark; acceptance clears the work.
    as_staff
    get "/api/v1/admin/portal_threads/#{request.client_portal_thread_id}"
    thread_data = data
    post "/api/v1/admin/portal_threads/#{request.client_portal_thread_id}/mark_read",
      params: { foreground: true, display_token: thread_data.fetch("display_token"), displayed_message_ids: thread_data.fetch("messages").map { |m| m["id"] } }, as: :json
    get "/api/v1/admin/client_inbox", params: { status: "all", kind: "file_request" }
    expect(response.parsed_body.dig("data", 0, "unread")).to be(false)
    post "/api/v1/admin/portal_file_requests/#{request.id}/accept", params: { response_message_id: request.reload.last_response_message_id }
    get "/api/v1/admin/client_inbox", params: { status: "waiting" }
    expect(response.parsed_body.fetch("data")).to be_empty
  end
end
