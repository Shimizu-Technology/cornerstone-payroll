# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Demo company presentation", type: :request do
  let!(:organization) { create(:organization) }
  let!(:home) { create(:company, organization: organization, name: "Firm HQ") }
  let!(:live) { create(:company, organization: organization, name: "Live Client") }
  let!(:demo) { create_demo_company(organization: organization) }
  let!(:sandbox) do
    create(:company, organization: organization, name: "Live Client practice", payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: live, migration_rehearsal_status: "ready",
      test_workspace_expires_at: 30.days.from_now)
  end
  let!(:admin) { create(:user, company: home, organization: organization, role: "admin") }
  let!(:accountant) { create(:user, company: home, organization: organization, role: "accountant") }

  let(:workspace_keys) do
    %w[
      test_workspace_purpose test_workspace_purpose_label test_workspace_expires_at test_workspace_archived_at
      test_workspace_sealed_at migration_rehearsal_status migration_source_company_id migration_source_company_name
      migration_source_batch_id migration_rehearsal_completed_at migration_rehearsal_error
    ]
  end

  before do
    [ live, demo ].each { |company| CompanyAssignment.create!(user: accountant, company: company, workspace_access_level: (company.test_workspace? ? "operator" : nil)) }
  end

  def sign_in(controller, user)
    allow_any_instance_of(controller).to receive(:current_user).and_return(user)
    allow_any_instance_of(controller).to receive(:current_user_id).and_return(user.id)
  end

  def expect_live_shape(row)
    expect(row).to include("payroll_environment" => "live", "test_workspace" => false,
      "test_workspace_expired" => false, "test_workspace_read_only" => false)
    workspace_keys.each { |key| expect(row[key]).to be_nil, "expected #{key} to be blank" }
  end

  it "lists a demo exactly like a live client in the staff client list" do
    sign_in(Api::V1::Admin::CompaniesController, admin)
    get "/api/v1/admin/companies"

    rows = response.parsed_body.fetch("companies").index_by { |row| row.fetch("id") }
    expect_live_shape(rows.fetch(demo.id))
    expect(rows.fetch(demo.id)["test_workspace_manifest"]).to eq({})
    expect(rows.fetch(sandbox.id)).to include("test_workspace" => true, "test_workspace_purpose" => "sandbox")
  end

  it "shows the company type to organization admins only" do
    sign_in(Api::V1::Admin::CompaniesController, admin)
    get "/api/v1/admin/companies/#{demo.id}"
    expect(response.parsed_body.dig("company", "company_type")).to eq("demo")
    get "/api/v1/admin/companies/#{live.id}"
    expect(response.parsed_body.dig("company", "company_type")).to eq("client")

    sign_in(Api::V1::Admin::CompaniesController, accountant)
    get "/api/v1/admin/companies"
    rows = response.parsed_body.fetch("companies").index_by { |row| row.fetch("id") }
    expect(rows.fetch(demo.id)).not_to have_key("company_type")
    expect_live_shape(rows.fetch(demo.id))
    expect(response.body).not_to include("demo_fixture_key")
  end

  it "serves the company switcher the live shape" do
    sign_in(Api::V1::CompaniesController, accountant)
    get "/api/v1/companies"

    row = response.parsed_body.fetch("companies").find { |company| company.fetch("id") == demo.id }
    expect_live_shape(row)
    expect(row).not_to have_key("company_type")
  end
end
