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

  # Every non-GET route in the client namespace, with real ids where a
  # controller looks the record up before the viewer guard runs
  # (DepartmentsController inherits the admin one's lookups).
  def client_write_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      verb = route.verb.to_s
      next unless path.start_with?("/api/v1/client/") && verb.present? && !verb.match?(/GET|HEAD/)

      action = "#{route.defaults[:controller]}##{route.defaults[:action]}"
      filled = path.gsub(/:company_id/, company.id.to_s).gsub(/:employee_id/, employee.id.to_s)
        .gsub(/:operation/, "invite").gsub(/:id/, path.include?("departments") ? department.id.to_s : "1")
        .gsub(/:[a-z_]+/, "1")
      verb.split("|").map { |single| [ single.downcase.to_sym, filled, action ] }
    end.flatten(1).uniq
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

  it "still lets a viewer record read receipts" do
    post "/api/v1/client/documents/999999/opened", headers: headers(viewer), as: :json
    expect(response).not_to have_http_status(:forbidden)
    post "/api/v1/client/portal_threads/999999/mark_read", headers: headers(viewer), as: :json
    expect(response).not_to have_http_status(:forbidden)
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

  it "tells the web app which level the login has" do
    get "/api/v1/auth/me", headers: headers(viewer)
    expect(response.parsed_body.dig("user", "client_access_level")).to eq("viewer")
    get "/api/v1/auth/me", headers: headers(manager)
    expect(response.parsed_body.dig("user", "client_access_level")).to eq("manager")
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
