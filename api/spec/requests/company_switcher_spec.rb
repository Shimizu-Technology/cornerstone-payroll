# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Company switcher context", type: :request do
  let!(:home_company) { create(:company, organization: create(:organization, name: "Cornerstone QA")) }
  let!(:shimizu_company) { create(:company, organization: create(:organization, name: "Shimizu Technology LLC")) }
  let!(:platform_user) { create(:user, role: "super_admin", company: home_company, organization: home_company.organization) }

  before do
    allow_any_instance_of(Api::V1::CompaniesController).to receive(:current_user).and_return(platform_user)
  end

  it "returns organization names and a valid selection after a stale company header" do
    get "/api/v1/companies", headers: { "X-Company-Id" => "999999999" }

    expect(response).to have_http_status(:ok)
    companies = response.parsed_body.fetch("companies")
    expect(companies.pluck("organization_name")).to contain_exactly("Cornerstone QA", "Shimizu Technology LLC")
    expect(companies).to all(include("payroll_intake_source_types" => []))
    expect(companies.pluck("id")).to include(response.parsed_body.fetch("current_company_id"))
  end

  it "shows Client Management to staff who can edit assigned clients, but not to client users" do
    { "super_admin" => true, "manager" => true, "accountant" => true }.each do |role, expected|
      platform_user.update!(role: role)
      get "/api/v1/companies"
      expect(response.parsed_body.fetch("can_view_client_management")).to be(expected), role
    end
    expect(response.parsed_body.fetch("can_manage_clients")).to be(false)

    client_user = create(:user, role: "client", company: home_company, organization: home_company.organization)
    allow_any_instance_of(Api::V1::CompaniesController).to receive(:current_user).and_return(client_user)
    get "/api/v1/companies"
    expect(response.parsed_body["can_view_client_management"]).not_to be(true)
  end
end
