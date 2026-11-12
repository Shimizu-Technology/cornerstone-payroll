# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Staff Client Inbox", type: :request do
  let(:org) { create(:organization) }
  let(:company) { create(:company, organization: org) }
  let(:second) { create(:company, organization: org) }
  let(:staff) { create(:user, company: company, organization: org, role: "org_admin", platform_owner: false, created_at: 1.year.ago) }
  let(:client) { create(:user, company: company, organization: org, role: "client", platform_owner: false) }

  before do
    actor = staff
    allow_any_instance_of(Api::V1::Admin::ClientInboxController).to receive(:current_user) { User.find(actor.id) }
  end

  def message_for(target)
    thread = create(:client_portal_thread, company: target, created_by: client)
    create(:client_portal_message, company: target, client_portal_thread: thread, author: client)
    thread
  end

  def rows(params = {})
    get "/api/v1/admin/client_inbox", params: params
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.fetch("data")
  end

  it "spans clients, ignores selected-company headers, and excludes other organizations/inactive clients" do
    threads = [ message_for(company), message_for(second) ]
    message_for(create(:company))
    second.update!(active: false)
    get "/api/v1/admin/client_inbox", headers: { "X-Company-Id" => second.id.to_s }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"].map { |r| r["id"] }).to eq([ threads.first.id ])
    second.update!(active: true)
    expect(rows.map { |r| r["company_id"] }).to contain_exactly(company.id, second.id)
  end

  it "denies client users and cross-organization context, including super admins" do
    allow_any_instance_of(Api::V1::Admin::ClientInboxController).to receive(:current_user).and_return(client)
    get "/api/v1/admin/client_inbox/counts"
    expect(response).to have_http_status(:forbidden)
    allow_any_instance_of(Api::V1::Admin::ClientInboxController).to receive(:current_user).and_return(staff)
    get "/api/v1/admin/client_inbox", headers: { "X-Organization-Id" => create(:organization).id.to_s }
    expect(response).to have_http_status(:forbidden)
    staff.update!(role: "super_admin")
    get "/api/v1/admin/client_inbox", headers: { "X-Organization-Id" => create(:organization).id.to_s }
    expect(response).to have_http_status(:forbidden)
    foreign_company = create(:company)
    message_for(foreign_company)
    expect(rows(company_id: foreign_company.id)).to be_empty
  end

  it "limits accountants to assignments and employee changes to client-management grants" do
    staff.update!(role: "accountant")
    first_assignment = create(:company_assignment, user: staff, company: company)
    create(:company_assignment, user: staff, company: second)
    [ company, second ].each do |target|
      message_for(target)
      create(:employee_change_request, company: target, employee: create(:employee, company: target), requested_by: client)
    end
    expect(rows.map { |r| r["kind"] }).to eq(%w[message message])
    # Existing grant shape is covered by the capability specs.
    first_assignment.update_columns(client_management: true, granted_by_id: client.id)
    expect(rows(kind: "employee_change").map { |r| r["company_id"] }).to eq([ company.id ])
    first_assignment.update_columns(expires_at: 1.minute.ago)
    expect(rows.map { |r| r["company_id"] }).to eq([ second.id ])
  end

  it "does not restore expired home-company assignments through fallback" do
    staff.update!(role: "manager")
    create(:company_assignment, user: staff, company: company, expires_at: 1.minute.ago)
    message_for(company)
    expect(rows).to be_empty
  end

  it "counts all pages across clients and separates personal unread from waiting on staff" do
    201.times { message_for(company) }
    201.times { create(:client_document, company: second, uploaded_by: client) }
    thread = message_for(second)
    create(:client_portal_message, company: second, client_portal_thread: thread, author: staff)
    get "/api/v1/admin/client_inbox/counts", params: { per_page: 2 }
    expect(response.parsed_body["data"]).to include("unread_count" => 403, "waiting_count" => 402, "unread_messages" => 202, "unread_documents" => 201)
    expect(rows(per_page: 2).size).to eq(2)
    expect(rows(status: "handled").first).to include("sender_name" => staff.name)
  end

  it "seeks through tied rows once and excludes new work until refreshed" do
    threads = 4.times.map { message_for(company) }
    ClientPortalMessage.update_all(created_at: 1.minute.ago.change(usec: 0))
    first = rows(per_page: 2)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    create(:client_portal_message, company: company, client_portal_thread: threads.first, author: client)
    newest = message_for(second)
    rest = rows(per_page: 2, cursor: cursor)
    expect((first + rest).map { |r| r["id"] }).to eq(threads.map(&:id).reverse)
    expect(rows.map { |r| r["id"] }).to include(newest.id)
    get "/api/v1/admin/client_inbox", params: { cursor: cursor, kind: "document" }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "treats a new client reply after resolution as work waiting on staff" do
    thread = message_for(company)
    thread.update!(status: "resolved", resolved_at: Time.current, resolved_by: staff)
    expect(rows(status: "waiting")).to be_empty
    create(:client_portal_message, company: company, client_portal_thread: thread, author: client)
    expect(rows(status: "waiting").map { |r| r["id"] }).to eq([ thread.id ])
  end

  it "preserves microsecond cursor precision across pages" do
    threads = 4.times.map { message_for(company) }
    base = 1.minute.ago.change(usec: 100_000)
    threads.each_with_index { |thread, index| thread.messages.update_all(created_at: base + index * 0.01) }
    first = rows(per_page: 2)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    second_page = rows(per_page: 2, cursor: cursor)
    expect((first + second_page).map { |r| r["id"] }).to eq(threads.map(&:id).reverse)
  end

  it "filters kind/status/client and rejects invalid filters/cursors" do
    message_for(company)
    create(:client_document, company: second, uploaded_by: client, reviewed_at: Time.current)
    expect(rows(kind: "document", company_id: second.id, status: "handled").size).to eq(1)
    expect(rows(kind: "document", status: "waiting")).to be_empty
    get "/api/v1/admin/client_inbox", params: { cursor: "bad" }
    expect(response).to have_http_status(:unprocessable_entity)
    get "/api/v1/admin/client_inbox/counts", params: { kind: "bad" }
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
