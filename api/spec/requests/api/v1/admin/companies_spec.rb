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
      expect(response.parsed_body).to include(
        "can_manage_clients" => true,
        "can_switch_company" => true
      )
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

  describe "assigned staff access" do
    let!(:accountant_user) do
      User.create!(
        company: staff_company,
        email: "assigned-accountant@example.com",
        name: "Assigned Accountant",
        role: "accountant",
        active: true
      )
    end

    before do
      CompanyAssignment.create!(user: accountant_user, company: client_company)
      allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(accountant_user)
      allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user_id).and_return(accountant_user.id)
      allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_company_id).and_return(client_company.id)
    end

    it "lets assigned accountants view assigned client details" do
      get "/api/v1/admin/companies/#{client_company.id}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("company")).to include(
        "id" => client_company.id,
        "can_update" => true,
        "editable_fields" => contain_exactly("address_line1", "address_line2", "city", "state", "zip", "phone", "email")
      )
    end

    it "lets assigned accountants update contact details but not admin-only fields" do
      patch "/api/v1/admin/companies/#{client_company.id}", params: {
        company: {
          name: "Should Not Change",
          ein: "99-9999999",
          address_line1: "123 Marine Corps Drive",
          phone: "671-555-0100"
        }
      }

      expect(response).to have_http_status(:ok)
      client_company.reload
      expect(client_company.name).to eq("Client A")
      expect(client_company.ein).not_to eq("99-9999999")
      expect(client_company.address_line1).to eq("123 Marine Corps Drive")
      expect(client_company.phone).to eq("671-555-0100")
    end

    it "prevents assigned accountants from updating unassigned clients" do
      patch "/api/v1/admin/companies/#{inactive_client_company.id}", params: {
        company: { address_line1: "Nope" }
      }

      expect(response).to have_http_status(:forbidden)
    end

    it "prevents non-staff users from updating company details even when they can access the company" do
      client_user = User.create!(
        company: client_company,
        email: "assigned-client@example.com",
        name: "Assigned Client",
        role: "client",
        active: true
      )
      CompanyAssignment.create!(user: client_user, company: client_company)
      allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:require_staff_access!)
      allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(client_user)
      allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user_id).and_return(client_user.id)

      patch "/api/v1/admin/companies/#{client_company.id}", params: {
        company: { address_line1: "Should Not Save" }
      }

      expect(response).to have_http_status(:forbidden)
      expect(client_company.reload.address_line1).not_to eq("Should Not Save")
    end
  end
end
