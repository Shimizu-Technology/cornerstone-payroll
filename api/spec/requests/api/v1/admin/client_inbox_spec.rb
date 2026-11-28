# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Staff Client Inbox", type: :request do
  include EmployeeLifecyclePr4Helpers

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

  it "includes and labels accessible practice copies but excludes expired or unassigned copies" do
    practice = create(:company, organization: org, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
      migration_source_company: company, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)
    message_for(practice)
    expect(rows.sole).to include("company_id" => practice.id, "practice_copy" => true)
    staff.update!(role: "accountant")
    create(:company_assignment, user: staff, company: company)
    expect(rows).to be_empty
    create(:company_assignment, user: staff, company: practice, workspace_access_level: "operator")
    expect(rows.sole).to include("practice_copy" => true)
    practice.update_columns(test_workspace_expires_at: 1.minute.ago)
    expect(rows).to be_empty
  end

  it "keeps practice activity out of live workload counts and excludes sealed copies" do
    practice = create(:company, organization: org, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
      migration_source_company: company, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)
    message_for(practice)
    message_for(company)
    expect(rows.size).to eq(2)
    get "/api/v1/admin/client_inbox/counts"
    expect(response.parsed_body["data"]).to include("unread_count" => 1, "waiting_count" => 1, "unread_messages" => 1)
    practice.update_columns(test_workspace_sealed_at: Time.current)
    expect(rows.map { |row| row["company_id"] }).to eq([ company.id ])
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

  it "lists a blocked scheduled activation only for companies the staff member can access" do
    [ company, create(:company) ].each do |target|
      profile = create_client_managed_profile!(target)
      profile.update!(lifecycle_mode_activated_at: nil, lifecycle_mode_activation_failed_at: 1.minute.ago,
        lifecycle_mode_activation_blockers: { "qualifying_staff_notification_recipients_count" => 0 })
    end
    expect(rows(kind: "lifecycle_activation_blocked", status: "waiting").sole).to include(
      "company_id" => company.id, "kind" => "lifecycle_activation_blocked", "waiting" => true
    )
    expect(rows(kind: "lifecycle_activation_blocked", status: "handled")).to be_empty

    stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF + [ "client_portal.employee_lifecycle_mode" ])
    expect(rows(kind: "lifecycle_activation_blocked", status: "waiting")).to be_empty
    expect(rows(status: "waiting").pluck("kind")).not_to include("lifecycle_activation_blocked")
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

  it "shows subject-only client conversations as waiting work without inventing unread messages" do
    thread = create(:client_portal_thread, company: company, created_by: client, subject: "Subject only")
    create(:client_portal_thread, company: company, created_by: staff, subject: "Staff-only draft")
    expect(rows(status: "waiting").map { |r| r["id"] }).to eq([ thread.id ])
    get "/api/v1/admin/client_inbox/counts"
    expect(response.parsed_body["data"]).to include("unread_count" => 0, "waiting_count" => 1)
    thread.update!(status: "resolved", resolved_at: Time.current, resolved_by: staff)
    expect(rows(status: "waiting")).to be_empty
  end

  it "retains client work and sender identity after the author changes role or is deleted" do
    original_name = client.name
    thread = message_for(company)
    client.update!(role: "accountant")
    expect(rows(status: "waiting").first).to include("id" => thread.id, "unread" => true, "sender_name" => original_name)
    client.destroy!
    expect(rows(status: "waiting").first).to include("id" => thread.id, "unread" => true, "sender_name" => original_name)
    expect(thread.messages.first.reload.author_id).to be_nil
    expect(thread.messages.first.author_audience).to eq("client")
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

  it "shows company-scoped payroll review approvals and change requests in Client Inbox and marks them handled after commit or unapprove" do
    ensure_verified_test_tax_years(2026)
    company.update!(client_payroll_approval_required: true)
    second.update!(client_payroll_approval_required: true)
    create(:company_assignment, user: client, company: company)
    second_client = create(:user, company: second, organization: org, role: "client")
    create(:company_assignment, user: second_client, company: second)

    emp1 = create(:employee, company: company)
    period1 = create(:pay_period, :calculated, company: company,
      start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
    create(:payroll_item, company: company, pay_period: period1, employee: emp1, gross_pay: 1_200, net_pay: 1_000)
    PayPeriodLifecycleService.new(pay_period: period1, actor: staff).approve!

    emp2 = create(:employee, company: second)
    period2 = create(:pay_period, :calculated, company: second,
      start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
    create(:payroll_item, company: second, pay_period: period2, employee: emp2, gross_pay: 900, net_pay: 750)
    PayPeriodLifecycleService.new(pay_period: period2, actor: staff).approve!

    # Published-only reviews without a client decision do not appear yet.
    expect(rows(kind: "payroll_review")).to be_empty

    PayrollReview::RevisionService.new(pay_period: period1, actor: client).approve!(
      approver: client, recorded_by: client, method: "client_portal",
      revision_id: period1.payroll_review_packages.current.first!.id,
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
    )
    PayrollReview::RevisionService.new(pay_period: period2, actor: second_client).request_changes!(
      revision_id: period2.payroll_review_packages.current.first!.id,
      note: "Adjust hours"
    )

    inbox = rows(kind: "payroll_review", status: "waiting")
    expect(inbox.size).to eq(2)
    approved_row = inbox.find { |r| r["company_id"] == company.id }
    changes_row = inbox.find { |r| r["company_id"] == second.id }
    expect(approved_row).to include(
      "kind" => "payroll_review",
      "pay_period_id" => period1.id,
      "state" => "approved",
      "state_label" => "Approved — ready to commit",
      "sender_name" => client.name,
      "waiting" => true
    )
    expect(changes_row).to include(
      "kind" => "payroll_review",
      "pay_period_id" => period2.id,
      "state" => "changes_requested",
      "state_label" => "Changes requested",
      "sender_name" => second_client.name,
      "waiting" => true
    )

    get "/api/v1/admin/client_inbox/counts"
    expect(response.parsed_body["data"]).to include("waiting_count" => 2, "waiting_payroll" => 2)

    # Company scoping respects staff assignments.
    staff.update!(role: "accountant")
    create(:company_assignment, user: staff, company: company)
    expect(rows(kind: "payroll_review").map { |r| r["company_id"] }).to eq([ company.id ])
    staff.update!(role: "org_admin")

    # Committing period1 and unapproving period2 move both entries from waiting to handled.
    PayPeriodLifecycleService.new(pay_period: period1.reload, actor: staff).commit!
    PayPeriodLifecycleService.new(pay_period: period2.reload, actor: staff).unapprove!(reason: "Fixture payroll approval correction")

    expect(rows(kind: "payroll_review", status: "waiting")).to be_empty
    handled = rows(kind: "payroll_review", status: "handled")
    expect(handled.map { |r| [ r["company_id"], r["state"] ] }).to contain_exactly(
      [ company.id, "approved" ],
      [ second.id, "changes_requested" ]
    )
  end
end
