# frozen_string_literal: true

require "rails_helper"

RSpec.describe "General test workspace administration", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:source_company) { create(:company, organization: organization, name: "Spike Coffee Roasters") }
  let(:admin) { create(:user, company: source_company, organization: organization, role: "admin") }
  let!(:accountant) { create(:user, company: source_company, organization: organization, role: "accountant") }
  let!(:employee) { create(:employee, company: source_company, department: nil) }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user_id).and_return(admin.id)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_company_id).and_return(source_company.id)
    3.times do |index|
      period = create(
        :pay_period,
        :committed,
        company: source_company,
        start_date: Date.new(2026, 7, 25) + (index * 14).days,
        end_date: Date.new(2026, 8, 7) + (index * 14).days,
        pay_date: Date.new(2026, 8, 14) + (index * 14).days
      )
      create(:payroll_item, company: source_company, pay_period: period, employee: employee, gross_pay: 1_000)
    end
  end

  after { clear_enqueued_jobs }

  it "previews and creates a general workspace with a chosen copy boundary" do
    get "/api/v1/admin/companies/#{source_company.id}/test_workspace_preview", params: {
      copy_mode: "exclude_recent",
      excluded_payrolls: 2
    }

    expect(response).to have_http_status(:ok)
    preview = response.parsed_body.fetch("test_workspace")
    expect(preview).to include("ready" => true, "copy_mode" => "exclude_recent")
    expect(preview.dig("copy_summary", "payrolls_to_copy")).to eq(1)

    post "/api/v1/admin/companies/#{source_company.id}/test_workspace", params: {
      name: "Spike Anything Goes Test",
      copy_mode: "exclude_recent",
      excluded_payrolls: 2,
      expiration_days: 60,
      acknowledgement: "CREATE TEST WORKSPACE",
      assignments: [ { user_id: accountant.id, workspace_access_level: "operator" } ]
    }

    expect(response).to have_http_status(:accepted)
    workspace = Company.find(response.parsed_body.dig("company", "id"))
    expect(workspace).to have_attributes(name: "Spike Anything Goes Test", test_workspace_purpose: "sandbox")
    expect(workspace.test_workspace_manifest.fetch("copied_source_pay_period_ids").length).to eq(1)
    expect(workspace.company_assignments.sole).to have_attributes(user: accountant, workspace_access_level: "operator")
    expect(TestWorkspace::CloneJob).to have_been_enqueued.with(workspace.id, admin.id)
  end

  it "archives and restores the workspace through explicit admin actions" do
    workspace = create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox",
      migration_source_company: source_company,
      migration_rehearsal_status: "ready",
      test_workspace_expires_at: 90.days.from_now
    )

    post "/api/v1/admin/companies/#{workspace.id}/archive_test_workspace"
    expect(response).to have_http_status(:ok)
    expect(workspace.reload.test_workspace_archived_at).to be_present

    post "/api/v1/admin/companies/#{workspace.id}/restore_test_workspace"
    expect(response).to have_http_status(:ok)
    expect(workspace.reload).to have_attributes(active: true, test_workspace_archived_at: nil)
  end
end
