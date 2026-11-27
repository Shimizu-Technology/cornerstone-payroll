# frozen_string_literal: true

require "rails_helper"

# A client viewer sees everything a client manager sees and changes nothing:
# ClientPortalAccess refuses every write in the client namespace. The write
# sweep reads the routes, so a new client write endpoint is covered without
# editing this spec.
RSpec.describe "Client viewer access", type: :request do
  include EmployeeLinkHelpers

  let(:company) { create(:company, name: "Example Bakery") }
  let(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department, email: "worker@example.test") }
  let(:viewer) { client_login("user_client_viewer", access_level: "viewer") }
  let(:manager) { client_login("user_client_manager", access_level: "manager") }

  def client_login(clerk_id, access_level:)
    create(:user, company: company, role: :client, clerk_id: clerk_id, client_access_level: access_level).tap do |user|
      CompanyAssignment.create!(user: user, company: company)
    end
  end

  def headers(user)
    bearer(user.clerk_id).merge("X-Company-Id" => company.id.to_s)
  end

  # Every write verb on every route in the client namespace, including a
  # route that also answers GET, with real ids where a controller looks the
  # record up before the viewer guard runs (DepartmentsController inherits
  # the admin one's lookups).
  def self.write_verbs(route)
    route.verb.to_s.split("|").reject { |verb| %w[GET HEAD].include?(verb) || verb.empty? }
  end

  def client_write_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      verbs = self.class.write_verbs(route)
      next unless path.start_with?("/api/v1/client/") && verbs.any?

      action = "#{route.defaults[:controller]}##{route.defaults[:action]}"
      filled = path.gsub(/:company_id/, company.id.to_s).gsub(/:employee_id/, employee.id.to_s)
        .gsub(/:operation/, "invite").gsub(/:id/, path.include?("departments") ? department.id.to_s : "1")
        .gsub(/:[a-z_]+/, "1")
      verbs.map { |verb| [ verb.downcase.to_sym, filled, action ] }
    end.flatten(1).uniq
  end

  it "counts a route that answers both GET and a write verb as a write" do
    route = Struct.new(:verb).new("GET|POST")
    expect(self.class.write_verbs(route)).to eq([ "POST" ])
    expect(self.class.write_verbs(Struct.new(:verb).new("GET"))).to eq([])
  end

  it "refuses every client write endpoint to a viewer with a plain 403" do
    routes = client_write_routes
    # The sweep found the writes this decision names.
    expect(routes.map(&:last)).to include(
      "api/v1/client/pay_periods#approve_review", "api/v1/client/pay_periods#request_changes",
      "api/v1/client/payroll_submission_periods#submissions", "api/v1/client/payroll_submission_periods#decision",
      "api/v1/client/employees#create", "api/v1/client/employees#update", "api/v1/client/departments#create",
      "api/v1/client/documents#create", "api/v1/client/documents#destroy", "api/v1/client/portal_threads#create",
      "api/v1/client/portal_messages#create", "api/v1/client/portal_file_requests#respond",
      "api/v1/client/employee_change_requests#approve", "api/v1/client/employee_change_requests#reject",
      "api/v1/client/employee_app_rollouts#bulk_invite", "api/v1/client/employee_app_rollouts#change",
      "api/v1/client/employee_app_settings#update_branding", "api/v1/client/employee_app_settings#upload_logo"
    )

    expect(routes.size).to be >= 25
    routes.each do |verb, path, action|
      next if ClientPortalAccess::VIEWER_WRITES.include?(action)

      public_send(verb, path, headers: headers(viewer), params: {}, as: :json)
      expect(response).to have_http_status(:forbidden), "#{verb.upcase} #{path} (#{action}) answered #{response.status}"
      expect(response.parsed_body).to eq("error" => ClientPortalAccess::VIEW_ONLY, "code" => "client_view_only"), action
    end
    expect(Department.where(company: company).count).to eq(1)
    expect(ClientDocument.count).to eq(0)
  end

  it "still records a viewer's own read receipts for a document and a conversation" do
    document = create(:client_document, company: company, uploaded_by: manager)
    post "/api/v1/client/documents/#{document.id}/opened", headers: headers(viewer), as: :json
    expect(response).to have_http_status(:no_content)
    expect(document.read_receipts.pluck(:user_id)).to eq([ viewer.id ])

    thread = create(:client_portal_thread, company: company, created_by: manager)
    create(:client_portal_message, client_portal_thread: thread, company: company, author: manager)
    get "/api/v1/client/portal_threads/#{thread.id}", headers: headers(viewer)
    shown = response.parsed_body.fetch("data")
    post "/api/v1/client/portal_threads/#{thread.id}/mark_read", headers: headers(viewer), as: :json,
      params: { foreground: true, display_token: shown.fetch("display_token"), displayed_message_ids: shown.fetch("messages").map { |message| message.fetch("id") } }
    expect(response).to have_http_status(:ok), response.body
    expect(PortalThreadReadReceipt.where(client_portal_thread: thread).pluck(:user_id)).to eq([ viewer.id ])
  end

  it "lets a viewer change their own notification preferences, which aren't a company change" do
    patch "/api/v1/notification_settings", headers: headers(viewer), as: :json, params: { preferences: { portal_replies: "digest" } }
    expect(response).to have_http_status(:ok), response.body
    expect(PortalNotificationPreference.where(user: viewer).pluck(:category)).to include("portal_replies")
  end

  it "lets a viewer read payroll, employees, reports, documents and messages" do
    reads = %W[
      /api/v1/client/pay_periods
      /api/v1/client/employees
      /api/v1/client/employees/#{employee.id}
      /api/v1/client/departments
      /api/v1/client/documents
      /api/v1/client/portal_threads
      /api/v1/client/portal_threads/unread_count
      /api/v1/client/employee_change_requests
      /api/v1/client/payroll_submission_periods
      /api/v1/client/reports/dashboard
      /api/v1/client/support_access_logs
      /api/v1/client/employee_intake_settings
      /api/v1/client/employee_app_rollout/#{company.id}
      /api/v1/client/employee_app_status/#{company.id}
      /api/v1/client/employee_app_status/#{company.id}/csv
      /api/v1/client/employees/#{employee.id}/employee_app
      /api/v1/client/pay_stubs/employee/#{employee.id}
    ]
    reads.each do |path|
      get path, headers: headers(viewer)
      expect(response).to have_http_status(:ok), "GET #{path} answered #{response.status}: #{response.body.first(200)}"
    end
  end

  it "keeps a client manager's writes working" do
    post "/api/v1/client/departments", headers: headers(manager), params: { department: { name: "Front of house" } }, as: :json
    expect(response).to have_http_status(:created)
  end

  it "assigns and renames managed roles with employee activity and rejects foreign departments" do
    path = "/api/v1/client/employee_organization"
    second = create(:employee, company: company)
    post "#{path}/save_role", headers: headers(manager), params: { role: { name: "Server", occupation_code: "102" } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    role_id = response.parsed_body.fetch("roles").sole.fetch("id")

    foreign_department = create(:department)
    patch path, headers: headers(manager), params: { employee_ids: [ employee.id, second.id ], department_id: foreign_department.id,
      company_job_role_id: role_id }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(employee.reload.company_job_role_id).to be_nil

    patch path, headers: headers(manager), params: { employee_ids: [ employee.id, second.id ], department_id: department.id,
      company_job_role_id: role_id }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect([ employee.reload.job_title, second.reload.job_title ]).to eq(%w[Server Server])
    expect(second.department_id).to eq(department.id)

    post "#{path}/save_role", headers: headers(manager), params: { id: role_id, role: { name: "Lead Server" } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(employee.reload.job_title).to eq("Lead Server")
    activity = AuditLog.where(company_id: company.id, record_type: "Employee", record_id: employee.id,
      action: "employee_organization#update").order(:id).last
    expect(activity.metadata.dig("after_values", "job_title")).to eq("Lead Server")
    expect(employee.employee_tipped_occupations).to be_empty
  end

  it "returns JSON validation errors for invalid assignment values and a missing role body" do
    path = "/api/v1/client/employee_organization"
    patch path, headers: headers(manager), params: { employee_ids: [ employee.id ], department_id: false }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to be_present

    post "#{path}/save_role", headers: headers(manager), params: {}, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Provide role details.")
  end

  it "denies a manager write when the locked workspace is read-only" do
    allow_any_instance_of(Company).to receive(:test_workspace_read_only?).and_return(true)
    patch "/api/v1/client/employee_organization", headers: headers(manager),
      params: { employee_ids: [ employee.id ], department_id: nil }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(employee.reload.department_id).to eq(department.id)
  end

  it "tells the web app which level the login has" do
    get "/api/v1/auth/me", headers: headers(viewer)
    expect(response.parsed_body.dig("user", "client_access_level")).to eq("viewer")
    get "/api/v1/companies", headers: headers(viewer)
    expect(response.parsed_body.fetch("companies").sole).to include("client_view_only" => true, "workspace_can_write" => false)
    get "/api/v1/client/employee_app_rollout/#{company.id}", headers: headers(viewer)
    expect(response.parsed_body.fetch("data")).to include("can_manage_invites" => false, "can_print_codes" => false)

    get "/api/v1/auth/me", headers: headers(manager)
    expect(response.parsed_body.dig("user", "client_access_level")).to eq("manager")
    get "/api/v1/companies", headers: headers(manager)
    expect(response.parsed_body.fetch("companies").sole).to include("client_view_only" => false, "workspace_can_write" => true)
  end

  it "defaults new client logins to manager and only allows the two levels" do
    user = create(:user, company: company, role: :client)
    expect(user.client_access_level).to eq("manager")
    expect(user).not_to be_client_viewer
    expect(build(:user, company: company, role: :client, client_access_level: "owner")).not_to be_valid
    expect { User.transaction(requires_new: true) { user.update_columns(client_access_level: "owner") } }
      .to raise_error(ActiveRecord::StatementInvalid, /users_client_access_level_check/)

    staff = create(:user, company: company, role: :accountant, client_access_level: "viewer")
    expect(staff.client_access_level).to eq("manager")
  end
end
