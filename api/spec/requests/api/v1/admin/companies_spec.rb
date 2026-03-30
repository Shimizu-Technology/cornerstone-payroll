require "rails_helper"

RSpec.describe "Api::V1::Admin::Companies", type: :request do
  let!(:staff_company) { create(:company, name: "Staff HQ") }
  let!(:client_company) { create(:company, name: "Client A") }
  let!(:inactive_client_company) { create(:company, name: "Inactive Client", active: false) }

  let!(:admin_user) do
    User.create!(
      company: staff_company,
      email: "companies-admin@example.com",
      name: "Companies Admin",
      role: "admin",
      active: true
    )
  end

  let!(:client_assignment) { CompanyAssignment.create!(user: admin_user, company: client_company) }
  let!(:inactive_assignment) { CompanyAssignment.create!(user: admin_user, company: inactive_client_company) }

  let!(:active_staff_employee) { create(:employee, company: staff_company, department: nil, status: "active") }
  let!(:inactive_staff_employee) { create(:employee, company: staff_company, department: nil, status: "inactive") }
  let!(:active_client_employee) { create(:employee, company: client_company, department: nil, status: "active") }

  before do
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user_id).and_return(admin_user.id)
  end

  describe "GET /api/v1/admin/companies" do
    it "returns accessible companies with active and total employee counts" do
      get "/api/v1/admin/companies"

      expect(response).to have_http_status(:ok)
      companies = response.parsed_body.fetch("companies")

      staff_payload = companies.find { |row| row.fetch("id") == staff_company.id }
      client_payload = companies.find { |row| row.fetch("id") == client_company.id }

      expect(staff_payload).to include(
        "active_employees" => 1,
        "total_employees" => 2
      )
      expect(client_payload).to include(
        "active_employees" => 1,
        "total_employees" => 1
      )
    end

    it "filters inactive companies when active=true" do
      get "/api/v1/admin/companies", params: { active: true }

      expect(response).to have_http_status(:ok)
      company_ids = response.parsed_body.fetch("companies").map { |row| row.fetch("id") }

      expect(company_ids).to include(staff_company.id, client_company.id)
      expect(company_ids).not_to include(inactive_client_company.id)
    end
  end
end
