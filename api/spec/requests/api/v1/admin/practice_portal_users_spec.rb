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
end
