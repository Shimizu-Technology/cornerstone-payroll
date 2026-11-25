# frozen_string_literal: true

require "rails_helper"

RSpec.describe "View-only support sessions", type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:grant_path) { "/api/v1/auth/view_as" }
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, subdomain_slug: "example-fixture") }
  let(:staff) { create(:user, company: company, role: :super_admin, view_as_allowed: true, clerk_id: "user_support", name: "Support Fixture") }
  let(:client) { create(:user, company: company, role: :client, clerk_id: "user_client", name: "Client Fixture") }
  let(:employee) { create(:employee, company: company, first_name: "Worker", last_name: "Fixture") }
  let(:employee_origin) { "https://example-fixture.shimizu-technology.com" }

  around do |example|
    saved = ENV["REQUIRE_MFA"]
    ENV["REQUIRE_MFA"] = "true"
    example.run
  ensure
    ENV["REQUIRE_MFA"] = saved
  end

  def authenticated(user = staff, **claims)
    bearer(user.clerk_id, **{ fva: [ 1, 1 ], two_factor_enabled: true }.merge(claims))
  end

  def start(target = client, type: "client", from: company, reason: "Investigate a display question", user: staff, **claims)
    post grant_path, params: { target_type: type, target_id: target.id, reason: reason }, as: :json,
      headers: authenticated(user, **claims).merge("X-Company-Id" => from.id.to_s)
  end

  def token_for(target = client, **options)
    start(target, **options)
    expect(response).to have_http_status(:created)
    response.parsed_body.fetch("token")
  end

  def viewing(token, user = staff, **claims)
    authenticated(user, **claims).merge(ViewAsGrant::HEADER => token)
  end

  def expect_view_as_failure_audit(request_id, status:)
    rows = AuditLog.where(request_id: request_id)
    expect(rows.find_by!(action: "portal_access#failed").metadata).to include("status" => status)
    expect(rows.distinct.pluck(:user_id, :real_user_id, :view_as_grant_id)).to eq([ [ staff.id, staff.id, ViewAsGrant.last.id ] ])
    expect(AuditLog.exists?(user_id: client.id)).to be(false)
  end

  def enable_employee_surface!(target = company)
    target.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service", hours_source: "manual",
      employee_portal_enabled: true, options: {
        subdomain_enabled: true, employee_portal: { features: { stubs: true, profile_requests: true } }
      }
    )
    TenantSubdomainRegistry.invalidate!
  end

  it "requires verified real staff, the explicit permission and a reason" do
    start(fva: [ 3, -1 ])
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include("code" => "mfa_required")

    start(fva: [ 20, 20 ])
    expect(response.parsed_body.dig("clerk_error", "reason")).to eq("reverification-error")
    expect(ViewAsGrant.count).to eq(0)

    start(reason: " ")
    expect(response).to have_http_status(:unprocessable_content)
    staff.update!(view_as_allowed: false)
    start
    expect(response).to have_http_status(:forbidden)

    staff.update!(role: :org_admin, view_as_allowed: true)
    start
    expect(response).to have_http_status(:forbidden)
    expect(ViewAsGrant.count).to eq(0)
  end

  it "rejects staff targets, out-of-organization companies, and targets without company access" do
    other_org_company = create(:company)
    other_org_client = create(:user, company: other_org_company, role: :client)
    other_company = create(:company, organization: organization)
    other_worker = create(:employee, company: other_company)

    start(staff)
    expect(response).to have_http_status(:not_found)
    start(other_org_client, from: other_org_company)
    expect(response).to have_http_status(:not_found)
    start(other_org_client)
    expect(response).to have_http_status(:not_found)
    start(client, from: other_company)
    expect(response).to have_http_status(:not_found)
    enable_employee_surface!
    start(other_worker, type: "employee")
    expect(response).to have_http_status(:not_found)
    expect(ViewAsGrant.count).to eq(0)
  end

  it "pins the client identity and company, rejects cross-company pulls, and leaves both login records untouched" do
    second = create(:company, organization: organization)
    create(:company_assignment, user: client, company: company)
    create(:company_assignment, user: client, company: second)
    token = token_for
    headers = viewing(token)
    outsider = create(:employee, company: second)

    get "/api/v1/auth/me", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("user")).to include(
      "id" => client.id, "role" => "client", "company_id" => company.id,
      "assigned_company_ids" => [ company.id ], "capabilities" => []
    )
    get "/api/v1/companies", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("companies").pluck("id")).to eq([ company.id ])
    expect(response.parsed_body).to include("can_switch_company" => false)

    get "/api/v1/client/reports/dashboard", headers: headers
    expect(response).to have_http_status(:ok)
    get "/api/v1/client/employees/#{outsider.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/api/v1/client/employees", headers: headers.merge("X-Company-Id" => second.id.to_s)
    expect(response).to have_http_status(:not_found)
    get "/api/v1/admin/employees", headers: headers
    expect(response).to have_http_status(:not_found)

    expect(staff.reload.last_active_at).to be_nil
    expect(client.reload.last_active_at).to be_nil
    expect(AuditLog.where(action: "authentication#signed_in").count).to eq(0)
  end

  it "refuses writes across payroll, client, signup and employee account controllers" do
    token = token_for
    headers = viewing(token)
    [
      [ :post, "/api/v1/auth/view_as" ],
      [ :post, "/api/v1/cable_ticket" ],
      [ :post, "/api/v1/admin/employees" ],
      [ :post, "/api/v1/client/employees" ],
      [ :patch, "/api/v1/client/departments/1" ],
      [ :delete, "/api/v1/client/documents/1" ],
      [ :post, "/api/v1/client/portal_threads/1/messages" ],
      [ :post, "/api/v1/client/portal_threads/1/mark_read" ],
      [ :post, "/api/v1/client/pay_periods/1/approve_review" ],
      [ :put, "/api/v1/client/employee_app_settings/help_contacts" ],
      [ :post, "/api/v1/form_500s/save" ]
    ].each do |verb, path|
      public_send(verb, path, headers: headers)
      expect(response).to have_http_status(:forbidden), "#{verb.upcase} #{path} returned #{response.status}"
      expect(response.parsed_body).to include("code" => "view_as_read_only")
    end

    enable_employee_surface!
    headers = viewing(token_for(employee, type: "employee"), azp: employee_origin)
    [
      [ :patch, "profile/phone" ], [ :post, "profile/email" ], [ :post, "profile/email/confirm" ],
      [ :post, "emergency_contacts" ], [ :delete, "address_requests/1" ], [ :post, "links/claim" ],
      [ :post, "links/reactivate" ], [ :post, "activation" ]
    ].each do |verb, path|
      public_send(verb, "/api/v1/employee/#{path}", headers: headers)
      expect(response).to have_http_status(:forbidden), "#{verb.upcase} #{path} returned #{response.status}"
    end
    expect(PortalNotificationEvent.count).to eq(0)
  end

  it "rejects a forged token, another user's token and a grant presented after permission revocation" do
    token = token_for
    other_admin = create(:user, company: company, role: :super_admin, view_as_allowed: true, clerk_id: "user_other_admin")
    get grant_path, headers: viewing(token, other_admin)
    expect(response).to have_http_status(:not_found)
    delete grant_path, headers: viewing(token, other_admin)
    expect(response).to have_http_status(:not_found)
    get grant_path, headers: viewing("a" * 43)
    expect(response).to have_http_status(:not_found)
    get grant_path, headers: viewing(token, fva: [ 3, -1 ])
    expect(response.parsed_body).to include("code" => "mfa_required")
    staff.update!(view_as_allowed: false)
    get grant_path, headers: viewing(token)
    expect(response).to have_http_status(:not_found)
    delete grant_path, headers: viewing(token)
    expect(response).to have_http_status(:no_content)
  end

  it "allows reads until 30 minutes, then fails closed, and ends a grant immediately when requested" do
    freeze_time do
      token = token_for
      expect(ViewAsGrant.last).to have_attributes(expires_at: 30.minutes.from_now, mode: "view_only",
        token_digest: Digest::SHA256.hexdigest(token), reason: "Investigate a display question")
      travel 29.minutes + 59.seconds
      head grant_path, headers: viewing(token)
      expect(response).to have_http_status(:ok)
      travel 1.second
      get grant_path, headers: viewing(token)
      expect(response).to have_http_status(:not_found)

      token = token_for
      delete grant_path, headers: viewing(token)
      expect(response).to have_http_status(:no_content)
      expect(ViewAsGrant.last.ended_at).to eq(Time.current)
      get "/api/v1/client/employees", headers: viewing(token)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "exposes only the matching company's support events to its client user" do
    token_for
    other = create(:company, organization: organization)
    peer = create(:user, role: :client, company: other, clerk_id: "user_peer", name: "Second Fixture")
    token_for(peer, from: other)
    AuditLog.record!(user: staff, company_id: company.id, action: "employees#update", record_type: "Employee")
    get "/api/v1/client/support_access_logs", headers: authenticated(client)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("events").pluck("description")).to eq([ "Support Fixture viewed as Client Fixture" ])
    expect(response.body).not_to include("Investigate", "employees#update", "Second Fixture")
    get "/api/v1/client/support_access_logs", headers: authenticated
    expect(response).to have_http_status(:forbidden)
  end

  it "opens the unlinked former worker on the employee host and leaves payroll and delivery untouched" do
    enable_employee_surface!
    employee.update!(status: "inactive", termination_date: PayrollBusinessClock.today - 7.days)
    period = create(:pay_period, :committed, company: company)
    create(:payroll_item, pay_period: period, employee: employee)
    token = token_for(employee, type: "employee")
    expect(response.parsed_body).to include("employee_url" => employee_origin)

    get grant_path, headers: viewing(token)
    expect(response).to have_http_status(:not_found)
    other = create(:company, organization: organization, subdomain_slug: "second-fixture")
    enable_employee_surface!(other)
    get grant_path, headers: viewing(token, azp: "https://second-fixture.shimizu-technology.com")
    expect(response).to have_http_status(:not_found)

    headers = viewing(token, azp: employee_origin)
    get grant_path, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("link", "status")).to eq("former")
    get "/api/v1/employee/context", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "former", "next_payday" => nil)
    get "/api/v1/employee/profile", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("legal_name" => employee.full_name)

    expect(R2StorageService).not_to receive(:new)
    expect(ClerkInvitationService).not_to receive(:new)
    expect do
      get "/api/v1/employee/statements", headers: headers
    end.not_to have_enqueued_job
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("statements")).to be_empty
    expect(EmployeeDocument.count).to eq(0)
    expect(EmployeeAccountLink.count).to eq(0)
    expect(PortalNotificationEvent.count).to eq(0)

    grant = ViewAsGrant.last
    expect(AuditLog.where(view_as_grant_id: grant.id).order(:id).pluck(:action)).to include("view_as#started", "employee_statement#listed")
    expect(AuditLog.where(view_as_grant_id: grant.id).distinct.pluck(:user_id, :real_user_id)).to eq([ [ staff.id, staff.id ] ])
    expect(staff.reload.last_active_at).to be_nil

    delete grant_path, headers: headers
    expect(response).to have_http_status(:no_content)
    get "/api/v1/employee/context", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "stamps the real actor on auditable reads even for a linked employee" do
    enable_employee_surface!
    login = create(:user, role: :portal_employee, company: company, clerk_id: "user_worker")
    EmployeeAccountLink.create!(employee: employee, company: company, user: login, status: "active")
    token = token_for(employee, type: "employee")
    get "/api/v1/employee/statements", headers: viewing(token, azp: employee_origin)
    expect(response).to have_http_status(:ok)
    log = AuditLog.find_by!(action: "employee_statement#listed")
    expect(log).to have_attributes(user_id: staff.id, real_user_id: staff.id, view_as_grant_id: ViewAsGrant.last.id, actor_name: staff.name)
    expect(AuditLog.exists?(user_id: login.id)).to be(false)
  end

  it "leaves pending document previews alone and attributes a read audit to the staff actor" do
    pending = create(:client_document, company: company, uploaded_by: client,
      file_name: "example.docx", preview_status: "pending")
    token = token_for
    expect(ClientDocumentPreviewGenerator).not_to receive(:new)
    storage = instance_double(R2StorageService)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:download).with(pending.file_key).and_return("fictional document")

    expect do
      get "/api/v1/client/documents/#{pending.id}/preview", headers: viewing(token).merge("X-Request-Id" => "support-preview")
    end.not_to change { pending.reload.attributes }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("unavailable while viewing")
    expect_view_as_failure_audit("support-preview", status: 422)

    get "/api/v1/client/documents/#{pending.id}/download", headers: viewing(token)
    expect(response).to have_http_status(:ok)
    row = AuditLog.find_by!(action: "portal_documents#download")
    expect(row).to have_attributes(user_id: staff.id, real_user_id: staff.id, view_as_grant_id: ViewAsGrant.last.id)
  end

  it "stamps a document download failure after the view-as context has reset" do
    token = token_for
    expect(R2StorageService).not_to receive(:new)

    get "/api/v1/client/documents/0/download", headers: viewing(token).merge("X-Request-Id" => "support-download")

    expect(response).to have_http_status(:not_found)
    expect_view_as_failure_audit("support-download", status: 404)
  end

  it "reads a quarterly compliance packet without creating a workflow" do
    token = token_for

    expect do
      get "/api/v1/client/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }, headers: viewing(token)
    end.not_to change(QuarterlyCompliancePacket, :count)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("report")).not_to have_key("workflow")
    expect(QuarterlyComplianceTask.count).to eq(0)
  end

  it "returns a clear response if a read would enqueue a job" do
    token = token_for
    allow(QuarterlyCompliancePacketBuilder).to receive(:new) do
      GenerateClientDocumentPreviewJob.perform_later(1)
    end

    expect do
      get "/api/v1/client/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }, headers: viewing(token)
    end.not_to have_enqueued_job

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include("error" => "This action is unavailable while viewing as another user.")
  end

  it "keeps the demo workspace client boundary and sends no messages" do
    demo = create_demo_company(organization: organization)
    # D5 will provision demo logins. Bind a fictional client to the demo in this fixture.
    user = create(:user, company: company, role: :client, clerk_id: "user_demo")
    user.update_columns(company_id: demo.id)
    token = token_for(user, from: demo)
    expect do
      get "/api/v1/client/employees", headers: viewing(token)
    end.not_to have_enqueued_job
    expect(response).to have_http_status(:ok)
    expect(PortalNotificationEvent.count).to eq(0)
    get "/api/v1/client/employees", headers: viewing(token).merge("X-Company-Id" => company.id.to_s)
    expect(response).to have_http_status(:not_found)
  end

  it "revokes access to an existing view when the employee link is locked" do
    enable_employee_surface!
    login = create(:user, role: :portal_employee, company: company)
    link = EmployeeAccountLink.create!(employee: employee, company: company, user: login, status: "active")
    token = token_for(employee, type: "employee")
    link.update!(activation_locked_until: 1.hour.from_now)

    get "/api/v1/employee/context", headers: viewing(token, azp: employee_origin)

    expect(response).to have_http_status(:not_found)
  end

  it "refuses an inactive unlinked employee without a termination date" do
    enable_employee_surface!
    employee.update!(status: "inactive", termination_date: nil)

    start(employee, type: "employee")

    expect(response).to have_http_status(:not_found)
    expect(ViewAsGrant.count).to eq(0)
  end

  it "refuses an employee view when the portal is disabled" do
    enable_employee_surface!
    token = token_for(employee, type: "employee")
    company.client_operating_profiles.sole.update!(employee_portal_enabled: false)
    TenantSubdomainRegistry.invalidate!

    get "/api/v1/employee/context", headers: viewing(token, azp: employee_origin)

    expect(response).to have_http_status(:not_found)
  end

  it "never resolves a staff-linked employee as another staff user" do
    enable_employee_surface!
    EmployeeAccountLink.create!(employee: employee, company: company, user: staff, status: "active")
    start(employee, type: "employee")
    expect(response).to have_http_status(:not_found)
    expect(ViewAsGrant.count).to eq(0)
  end
end
