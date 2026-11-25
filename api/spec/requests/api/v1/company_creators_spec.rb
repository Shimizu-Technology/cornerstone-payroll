# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Company creator summaries", type: :request do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, role: :admin, company: company, organization: company.organization) }

  before do
    allow_any_instance_of(Api::V1::CompaniesController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::CompaniesController).to receive(:current_company_id).and_return(company.id)
  end

  it "includes proven creators for staff and leaves old records unknown" do
    AuditLog.where(record_type: "companies", record_id: company.id).delete_all
    Current.user = actor
    tracked = create(:company, organization: company.organization)
    Current.reset
    get "/api/v1/companies"
    expect(response).to have_http_status(:ok)
    summaries = response.parsed_body.fetch("companies").index_by { |row| row.fetch("id") }
    expect(summaries.fetch(company.id)["creator"]).to be_nil
    expect(summaries.fetch(tracked.id).dig("creator", "name")).to eq(actor.name)
  end

  it "does not add creator data to client portal responses" do
    actor.update!(role: :client)
    CompanyAssignment.create!(user: actor, company: company)
    get "/api/v1/companies"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("companies")).not_to be_empty
    response.parsed_body.fetch("companies").each { |row| expect(row).not_to have_key("creator") }
  end
end
