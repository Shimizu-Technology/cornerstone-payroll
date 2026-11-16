# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Test-workspace operators and rehiring", type: :request do
  let!(:home) { create(:company) }
  let!(:workspace) do
    create(:company, organization: home.organization, payroll_environment: "migration_rehearsal",
      migration_source_company: home, migration_rehearsal_status: "ready",
      test_workspace_purpose: "sandbox", test_workspace_expires_at: 1.day.from_now)
  end
  let!(:manager) { create(:user, role: "manager", company: home, organization: home.organization) }
  let!(:grant) { create(:company_assignment, user: manager, company: workspace, workspace_access_level: "operator") }

  before do
    actor_id = manager.id
    allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user) { User.find(actor_id) }
  end

  it "refuses an operator's rehire of a terminated worker but allows reactivating an inactive one" do
    terminated = create(:employee, company: workspace, department: nil, hire_date: Date.new(2024, 1, 1),
      status: "terminated", termination_date: Date.new(2024, 3, 15))
    post "/api/v1/admin/employees/#{terminated.id}/reactivate", headers: { "X-Company-Id" => workspace.id.to_s },
      params: { reactivation: { effective_date: "2024-04-01", internal_notes: "Returned to work" } }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(terminated.reload.status).to eq("terminated")

    inactive = create(:employee, company: workspace, department: nil, hire_date: Date.new(2024, 1, 1), status: "inactive")
    post "/api/v1/admin/employees/#{inactive.id}/reactivate", headers: { "X-Company-Id" => workspace.id.to_s },
      params: { reactivation: { effective_date: "2024-04-01", internal_notes: "Returned to work" } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(inactive.reload.status).to eq("active")
  end
end
