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
    expect(companies.pluck("id")).to include(response.parsed_body.fetch("current_company_id"))
  end
end
