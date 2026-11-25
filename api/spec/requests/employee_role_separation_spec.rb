# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee identity access", type: :request do
  let(:user) { create(:user, role: :portal_employee, clerk_id: "user_employee") }
  let(:employee) { create(:employee, company: user.company) }
  let(:link) { EmployeeAccountLink.create!(user: user, company: user.company, employee: employee, status: :active) }
  let(:headers) { { "Authorization" => "Bearer valid.token", "X-Employee-Link-Id" => link.id.to_s } }

  before do
    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(false)
    allow_any_instance_of(ClerkTokenVerifier).to receive(:verify).and_return("sub" => user.clerk_id)
  end

  it "returns 404 with a valid employee link while the company feature is off" do
    get "/api/v1/employee/context", headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it "does not fall back to a dev admin or accept the company header as a link" do
    get "/api/v1/employee/context", headers: { "X-Company-Id" => user.company_id.to_s }

    expect(response).to have_http_status(:not_found)
  end

  it "does not resolve a link owned by another subject, even when the feature is enabled" do
    other_user = create(:user, company: user.company, clerk_id: "user_staff")
    allow_any_instance_of(ClerkTokenVerifier).to receive(:verify).and_return("sub" => other_user.clerk_id)
    allow_any_instance_of(CompanyFeatures).to receive(:employee_portal_enabled?).and_return(true)

    get "/api/v1/employee/context", headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it "denies both legacy and portal employee identities on staff and client routes" do
    %i[employee portal_employee].each do |role|
      user.update!(role: role)

      get "/api/v1/admin/employees", headers: headers
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/client/employees", headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    expect(user.accessible_company_ids).to be_empty
  end

  it "counts only eligible links behind the company flag without granting staff or client access" do
    get "/api/v1/auth/me", headers: headers
    expect(response.parsed_body.fetch("roles")).to eq("staff" => false, "client" => false, "employee_links_count" => 0)
    expect(response.parsed_body.dig("user", "company_id")).to be_nil

    allow_any_instance_of(CompanyFeatures).to receive(:employee_portal_enabled?).and_return(true)
    get "/api/v1/auth/me", headers: headers
    expect(response.parsed_body.dig("roles", "employee_links_count")).to eq(1)

    get "/api/v1/employee/context", headers: headers
    expect(response).to have_http_status(:ok)
  end
end
