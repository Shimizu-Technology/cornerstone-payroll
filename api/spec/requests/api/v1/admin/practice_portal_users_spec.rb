require "rails_helper"

RSpec.describe "Practice portal invitations and assignments", type: :request do
  let(:source) { create(:company) }
  let(:admin) { create(:user, company: source, role: "admin") }
  let(:workspace) do
    create(:company, organization: source.organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: source, migration_rehearsal_status: "ready",
      test_workspace_expires_at: 1.day.from_now)
  end
  before do
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:create_clerk_invitation).and_return(success: false, error: "Test: outbound blocked")
  end

  it "invites a separately scoped client and rejects mixing or changing it to a real client" do
    post "/api/v1/admin/users", params: { user: { email: "practice@example.invalid", name: "Practice login", role: "client", company_ids: [ workspace.id ] } }
    expect(response).to have_http_status(:created), response.body
    user = User.find(response.parsed_body.dig("data", "id"))
    expect(user).to have_attributes(company_id: workspace.id, practice_company_id: workspace.id)
    expect(user.company_assignments.sole.company).to eq(workspace)
    patch "/api/v1/admin/users/#{user.id}", params: { user: { company_ids: [ source.id, workspace.id ] } }
    expect(response).to have_http_status(:unprocessable_entity)
    post "/api/v1/admin/company_assignments", params: { company_assignment: { user_id: user.id, company_id: source.id } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(user.reload.company_assignments.pluck(:company_id)).to eq([ workspace.id ])
    patch "/api/v1/admin/users/#{user.id}", params: { user: { role: "admin", company_ids: [] } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(user.reload.role).to eq("client")
    put "/api/v1/admin/company_assignments/bulk_update", params: { user_id: user.id, company_ids: [ source.id, workspace.id ] }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(user.reload.company_assignments.pluck(:company_id)).to eq([ workspace.id ])
  end

  it "allows the practice client dashboard without granting staff report access" do
    user = create(:user, company: workspace, practice_company: workspace, role: "client")
    CompanyAssignment.create!(user: user, company: workspace, granted_by: admin)
    create(:employee, company: workspace)
    allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_user).and_return(user)
    get "/api/v1/client/reports/dashboard", headers: { "X-Company-Id" => workspace.id.to_s }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("stats", "active_employees")).to eq(1)
    expect(TestWorkspaceAccessPolicy.allowed?(user: user, company: workspace, request_method: "GET",
      controller_path: "api/v1/admin/reports")).to be(false)
    get "/api/v1/client/reports/dashboard", headers: { "X-Company-Id" => source.id.to_s }
    expect(response).to have_http_status(:forbidden)
  end

  it "shows the practice login its copied history but not the practice run" do
    user = create(:user, company: workspace, practice_company: workspace, role: "client")
    CompanyAssignment.create!(user: user, company: workspace, granted_by: admin)
    employee = create(:employee, company: workspace)
    source_period = create(:pay_period, :committed, company: source, start_date: Date.new(2026, 10, 5),
      end_date: Date.new(2026, 10, 18), pay_date: Date.new(2026, 10, 22))
    baseline = create(:pay_period, :approved, company: workspace, parallel_run: true, start_date: source_period.start_date,
      end_date: source_period.end_date, pay_date: source_period.pay_date)
    create(:payroll_item, pay_period: baseline, company: workspace, employee: employee, gross_pay: 1000, net_pay: 810)
    # The cloner writes copied history before sealing it as a baseline.
    baseline.update_columns(test_workspace_role: "baseline", test_workspace_source_pay_period_id: source_period.id)
    practice = create(:pay_period, :approved, company: workspace, start_date: Date.new(2026, 10, 19),
      end_date: Date.new(2026, 11, 1), pay_date: Date.new(2026, 11, 5))
    [ Api::V1::Client::PayPeriodsController, Api::V1::Client::ReportsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(user)
    end
    headers = { "X-Company-Id" => workspace.id.to_s }

    get "/api/v1/client/pay_periods", headers: headers
    expect(response).to have_http_status(:ok), response.body
    ids = response.parsed_body.fetch("pay_periods").map { |row| row.fetch("id") }
    expect(ids).to include(baseline.id)
    expect(ids).not_to include(practice.id)

    get "/api/v1/client/pay_periods", params: { register_eligible: true }, headers: headers
    expect(response.parsed_body.fetch("pay_periods").map { |row| row.fetch("id") }).to eq([ baseline.id ])

    get "/api/v1/client/pay_periods/#{baseline.id}", headers: headers
    expect(response).to have_http_status(:ok), response.body
    get "/api/v1/client/pay_periods/#{practice.id}", headers: headers
    expect(response).to have_http_status(:not_found)

    get "/api/v1/client/reports/payroll_register", params: { pay_period_id: baseline.id }, headers: headers
    expect(response).to have_http_status(:ok), response.body
    get "/api/v1/client/reports/dashboard", headers: headers
    expect(response.parsed_body.dig("stats", "current_pay_period", "id")).to eq(baseline.id)
  end

  it "lets a practice login add an employee to its own open copy only" do
    user = create(:user, company: workspace, practice_company: workspace, role: "client")
    CompanyAssignment.create!(user: user, company: workspace, granted_by: admin)
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_user).and_return(user)
    params = { employee: { first_name: "Taylor", last_name: "Cruz", ssn: "123-45-6789", ssn_confirmation: "123-45-6789",
      employment_type: "hourly", salary_type: "hourly", pay_rate: 16.25, filing_status: "single",
      hire_date: "2026-04-01", w4_effective_on: "2026-04-01", address_line1: "1 St", city: "Hagatna", state: "GU", zip: "96910" } }

    post "/api/v1/client/employees", headers: { "X-Company-Id" => workspace.id.to_s }, params: params
    expect(response).to have_http_status(:created), response.body
    post "/api/v1/client/employees", headers: { "X-Company-Id" => source.id.to_s }, params: params
    expect(response).to have_http_status(:forbidden)
    expect(source.employees.where(last_name: "Cruz")).to be_empty

    workspace.update_columns(test_workspace_sealed_at: Time.current)
    expect {
      post "/api/v1/client/employees", headers: { "X-Company-Id" => workspace.id.to_s }, params: params
    }.not_to change(Employee, :count)
    expect(response).to have_http_status(:forbidden)
    workspace.update_columns(test_workspace_sealed_at: nil)

    TestWorkspace::Lifecycle.new(company: workspace, actor: admin).archive!
    allow_any_instance_of(Api::V1::Client::EmployeesController).to receive(:current_user).and_return(User.find(user.id))
    expect {
      post "/api/v1/client/employees", headers: { "X-Company-Id" => workspace.id.to_s }, params: params
    }.not_to change(Employee, :count)
    expect(response).to have_http_status(:forbidden).or have_http_status(:unprocessable_entity)
  end

  it "rejects a mixed invitation and leaves no account or invitation behind" do
    expect {
      post "/api/v1/admin/users", params: { user: { email: "mixed@example.invalid", role: "client", company_ids: [ source.id, workspace.id ] } }
    }.not_to change(User, :count)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "rejects assigning a real client login to a practice copy" do
    user = create(:user, company: source, role: "client")
    post "/api/v1/admin/company_assignments", params: { company_assignment: { user_id: user.id, company_id: workspace.id } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(user.reload.company_assignments).to be_empty
    allow_any_instance_of(Api::V1::Client::PayPeriodsController).to receive(:current_user).and_return(user)
    get "/api/v1/client/pay_periods", headers: { "X-Company-Id" => workspace.id.to_s }
    expect(response).to have_http_status(:forbidden)
  end
  it "reactivates and restores a removed practice assignment in one atomic PATCH" do
    user = create(:user, company: workspace, practice_company: workspace, role: "client")
    user.update_columns(active: false)
    patch "/api/v1/admin/users/#{user.id}", params: { user: { active: true, company_ids: [ workspace.id ] } }
    expect(response).to have_http_status(:ok), response.body
    expect(user.reload).to be_active
    expect(user.company_assignments.sole.company_id).to eq(workspace.id)
    user.update_columns(active: false)
    user.company_assignments.delete_all
    patch "/api/v1/admin/users/#{user.id}", params: { user: { active: true, name: "", company_ids: [ workspace.id ] } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(user.reload).not_to be_active
    expect(user.company_assignments).to be_empty
  end

  it "allows the practice portal surfaces only in its own copy" do
    user = create(:user, company: workspace, practice_company: workspace, role: "client")
    CompanyAssignment.create!(user: user, company: workspace, granted_by: admin)
    employee = create(:employee, company: workspace)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(user.id)
    paths = %w[departments documents portal_threads portal_threads/unread_count employee_change_requests
      employees employee_intake_settings pay_periods payroll_submission_periods reports/dashboard reports/annual_payroll_summary]
    paths << "employees/#{employee.id}/document_requirements"
    paths.each do |path|
      get "/api/v1/client/#{path}", headers: { "X-Company-Id" => workspace.id.to_s }
      expect(response).to have_http_status(:ok), "#{path}: #{response.status} #{response.body}"
      get "/api/v1/client/#{path}", headers: { "X-Company-Id" => source.id.to_s }
      expect(response).to have_http_status(:forbidden), path
    end
    # Pay statements are served in client period details; the admin PDF endpoint
    # remains staff-only. Notification settings are personal, never company data.
    get "/api/v1/notification_settings", headers: { "X-Company-Id" => workspace.id.to_s }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data")).not_to have_key("administration")
    get "/api/v1/admin/portal_notification_recipients", headers: { "X-Company-Id" => source.id.to_s }
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/client/departments", headers: { "X-Company-Id" => workspace.id.to_s }, params: { department: { name: "Practice kitchen" } }
    expect(response).to have_http_status(:created), response.body
    department_id = response.parsed_body.dig("data", "id")
    patch "/api/v1/client/employees/#{employee.id}", headers: { "X-Company-Id" => workspace.id.to_s },
      params: { employee: { city: "Practice city", department_id: department_id } }
    expect(response).to have_http_status(:ok), response.body
    expect(employee.reload.city).to eq("Practice city")
    expect(employee.department_id).to eq(department_id)
    patch "/api/v1/client/employees/#{employee.id}", headers: { "X-Company-Id" => source.id.to_s },
      params: { employee: { city: "Forbidden city" } }
    expect(response).to have_http_status(:forbidden)
    expect(employee.reload.city).to eq("Practice city")
    post "/api/v1/client/departments", headers: { "X-Company-Id" => source.id.to_s }, params: { department: { name: "Forbidden kitchen" } }
    expect(response).to have_http_status(:forbidden)
  end
end
