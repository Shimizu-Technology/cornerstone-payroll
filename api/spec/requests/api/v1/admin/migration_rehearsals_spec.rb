# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::MigrationRehearsals", type: :request do
  let(:organization) { create(:organization) }
  let(:source_company) { create(:company, organization: organization, historical_payroll_enabled: true) }
  let(:admin) { create(:user, company: source_company, organization: organization, role: "admin") }

  before do
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user_id).and_return(admin.id)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_company_id).and_return(source_company.id)
  end

  it "returns a clear blocker when the source has no locked import" do
    get "/api/v1/admin/companies/#{source_company.id}/migration_rehearsal_preview"

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch("migration_rehearsal")
    expect(payload.fetch("ready")).to be(false)
    expect(payload.fetch("blockers")).to include("Lock a verified historical import before creating a rehearsal")
  end

  it "queues creation through the protected service and returns the pending company" do
    batch = create(:historical_import_batch, company: source_company, status: "locked")
    target = create(
      :company,
      organization: organization,
      name: "Migration Test",
      payroll_environment: "migration_rehearsal",
      migration_source_company: source_company,
      migration_source_batch: batch,
      migration_rehearsal_status: "pending"
    )
    creator = instance_double(MigrationRehearsal::Create, call: target)
    allow(MigrationRehearsal::Create).to receive(:new).and_return(creator)

    post "/api/v1/admin/companies/#{source_company.id}/migration_rehearsal", params: {
      historical_import_batch_id: batch.id,
      acknowledgement: MigrationRehearsal::Create::ACKNOWLEDGEMENT
    }

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("company", "payroll_environment")).to eq("migration_rehearsal")
    expect(response.parsed_body.dig("company", "migration_rehearsal_status")).to eq("pending")
  end

  it "does not allow an accountant to copy protected employee data" do
    accountant = create(:user, company: source_company, organization: organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(accountant)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user_id).and_return(accountant.id)

    get "/api/v1/admin/companies/#{source_company.id}/migration_rehearsal_preview"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Admin access required")
  end
end
