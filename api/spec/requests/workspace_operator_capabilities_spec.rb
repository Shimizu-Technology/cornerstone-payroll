# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Effective workspace operator capabilities", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:home) { create(:company) }
  let(:workspace) { create(:company, organization: home.organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox", migration_source_company: home, migration_rehearsal_status: "ready", test_workspace_expires_at: 10.days.from_now) }
  let(:user) { create(:user, company: home, organization: home.organization, role: "accountant") }

  before do
    create(:company_assignment, company: home, user: user)
    allow_any_instance_of(Api::V1::CompaniesController).to receive(:current_user).and_return(user)
  end

  it "distinguishes reviewer from operator on the same editable workspace" do
    assignment = create(:company_assignment, company: workspace, user: user, workspace_access_level: "reviewer")
    get "/api/v1/companies"
    expect(response).to have_http_status(:ok)
    rows = response.parsed_body.fetch("companies").index_by { |row| row.fetch("id") }
    expect(rows.fetch(workspace.id)).to include("workspace_can_write" => false, "test_workspace_read_only" => false)
    expect(rows.fetch(home.id).fetch("workspace_can_write")).to be(true)

    assignment.update!(workspace_access_level: "operator")
    get "/api/v1/companies"
    expect(response.parsed_body.fetch("companies").find { |row| row["id"] == workspace.id }.fetch("workspace_can_write")).to be(true)
  end

  it "keeps expired or sealed workspaces read-only despite operator access" do
    create(:company_assignment, company: workspace, user: user, workspace_access_level: "operator")
    travel_to(workspace.test_workspace_expires_at + 1.second) do
      get "/api/v1/companies"
      row = response.parsed_body.fetch("companies").find { |entry| entry["id"] == workspace.id }
      expect(row).to include("workspace_can_write" => false, "test_workspace_expired" => true)
    end
    workspace.update!(test_workspace_sealed_at: Time.current)
    get "/api/v1/companies"
    expect(response.parsed_body.fetch("companies").find { |row| row["id"] == workspace.id }.fetch("workspace_can_write")).to be(false)
  end
end
