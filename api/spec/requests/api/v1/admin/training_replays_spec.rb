# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Training replay administration", type: :request do
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
    create_source_period(Date.new(2026, 8, 22), Date.new(2026, 9, 4), Date.new(2026, 9, 11))
    create_source_period(Date.new(2026, 9, 5), Date.new(2026, 9, 18), Date.new(2026, 9, 25))
  end

  after { clear_enqueued_jobs }

  it "previews the exact two benchmark periods and eligible staff" do
    create_source_period(Date.new(2026, 8, 8), Date.new(2026, 8, 21), Date.new(2026, 8, 28))

    get "/api/v1/admin/companies/#{source_company.id}/training_replay_preview"

    expect(response).to have_http_status(:ok)
    preview = response.parsed_body.fetch("training_replay")
    expect(preview).to include("ready" => true)
    expect(preview.fetch("practice_periods").length).to eq(2)
    expect(preview.dig("copy_summary", "baseline_pay_periods")).to eq(1)
    expect(preview.fetch("assignable_staff").sole).to include(
      "id" => accountant.id,
      "role" => "accountant"
    )
  end

  it "creates the workspace only with acknowledgement and explicit valid access" do
    post "/api/v1/admin/companies/#{source_company.id}/training_replay", params: {
      name: "Spike Payroll Training",
      acknowledgement: "CREATE TRAINING REPLAY",
      assignments: [ { user_id: accountant.id, workspace_access_level: "reviewer" } ]
    }

    expect(response).to have_http_status(:accepted)
    company = Company.find(response.parsed_body.dig("company", "id"))
    expect(company).to have_attributes(name: "Spike Payroll Training", test_workspace_purpose: "training_replay")
    expect(company.company_assignments.sole).to have_attributes(user: accountant, workspace_access_level: "reviewer")
  end

  it "rejects client users and missing staff assignments" do
    client_user = create(:user, company: source_company, organization: organization, role: "client")

    post "/api/v1/admin/companies/#{source_company.id}/training_replay", params: {
      acknowledgement: "CREATE TRAINING REPLAY",
      assignments: [ { user_id: client_user.id, workspace_access_level: "operator" } ]
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors").join).to include("active managers and accountants")
    expect(source_company.test_workspaces.where(test_workspace_purpose: "training_replay")).to be_empty
  end

  private

  def create_source_period(start_date, end_date, pay_date)
    period = create(
      :pay_period,
      :committed,
      company: source_company,
      start_date: start_date,
      end_date: end_date,
      pay_date: pay_date
    )
    create(:payroll_item, pay_period: period, company: source_company, employee: employee, gross_pay: 1_000)
  end
end
