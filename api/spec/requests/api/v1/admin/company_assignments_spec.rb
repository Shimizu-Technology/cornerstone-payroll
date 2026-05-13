# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::CompanyAssignments", type: :request do
  let!(:organization) { create(:organization, name: "Staff Firm") }
  let!(:staff_company) { create(:company, organization: organization, name: "Staff HQ") }
  let!(:client_company) { create(:company, organization: organization, name: "Accessible Client") }
  let!(:other_company) { create(:company, organization: organization, name: "Second Client") }
  let!(:switched_staff_company) { create(:company, organization: organization, name: "Switched Staff HQ") }
  let!(:foreign_organization) { create(:organization, name: "Foreign Firm") }

  let!(:admin_user) do
    User.create!(
      company: staff_company,
      organization: organization,
      email: "assignment-admin@example.com",
      name: "Assignment Admin",
      role: "admin",
      active: true
    )
  end

  let!(:managed_user) do
    User.create!(
      company: staff_company,
      organization: organization,
      email: "assignment-user@example.com",
      name: "Managed User",
      role: "accountant",
      active: true
    )
  end

  let!(:foreign_staff_company) { create(:company, organization: foreign_organization, name: "Foreign Staff HQ") }
  let!(:foreign_client_company) { create(:company, organization: foreign_organization, name: "Foreign Client") }
  let!(:foreign_user) do
    User.create!(
      company: foreign_staff_company,
      organization: foreign_organization,
      email: "foreign-assignment-user@example.com",
      name: "Foreign User",
      role: "admin",
      active: true
    )
  end
  let!(:switched_managed_user) do
    User.create!(
      company: switched_staff_company,
      organization: organization,
      email: "switched-assignment-user@example.com",
      name: "Switched User",
      role: "accountant",
      active: true
    )
  end
  let!(:employee_user) do
    User.create!(
      company: staff_company,
      organization: organization,
      email: "assignment-employee@example.com",
      name: "Employee User",
      role: "employee",
      active: true
    )
  end

  let!(:admin_access_assignment) { CompanyAssignment.create!(user: admin_user, company: client_company) }
  let!(:managed_assignment) { CompanyAssignment.create!(user: managed_user, company: client_company) }
  let!(:foreign_assignment) { CompanyAssignment.create!(user: foreign_user, company: foreign_client_company) }
  let!(:switched_assignment) { CompanyAssignment.create!(user: switched_managed_user, company: client_company) }
  let!(:employee_assignment) { CompanyAssignment.create!(user: employee_user, company: client_company) }

  before do
    allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user_id).and_return(admin_user.id)
  end

  describe "GET /api/v1/admin/company_assignments" do
    it "does not leak assignments for users in other staff companies" do
      get "/api/v1/admin/company_assignments", params: { user_id: managed_user.id }

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      expect(data.map { |row| row.fetch("id") }).to eq([managed_assignment.id])
      expect(data.map { |row| row.fetch("user_id") }).not_to include(foreign_user.id)
      expect(data.map { |row| row.fetch("user_id") }).not_to include(employee_user.id)
    end

    it "keeps admins scoped to their staff company even when switched to another client" do
      allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_company_id).and_return(switched_staff_company.id)

      get "/api/v1/admin/company_assignments", params: { user_id: managed_user.id }

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      expect(data.map { |row| row.fetch("id") }).to eq([managed_assignment.id])
      expect(data.map { |row| row.fetch("user_id") }).not_to include(switched_managed_user.id)
    end
  end

  describe "DELETE /api/v1/admin/company_assignments/:id" do
    it "rejects deleting an assignment outside the caller's scoped users" do
      expect {
        delete "/api/v1/admin/company_assignments/#{foreign_assignment.id}"
      }.not_to change(CompanyAssignment, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PUT /api/v1/admin/company_assignments/bulk_update" do
    it "allows admins to assign any payroll client they can access globally" do
      put "/api/v1/admin/company_assignments/bulk_update",
        params: { user_id: managed_user.id, company_ids: [other_company.id] }

      expect(response).to have_http_status(:ok)
      expect(managed_user.company_assignments.reload.map(&:company_id)).to eq([other_company.id])
    end

    it "rejects assignment writes for employee users" do
      expect {
        put "/api/v1/admin/company_assignments/bulk_update",
          params: { user_id: employee_user.id, company_ids: [other_company.id] }
      }.not_to change { employee_user.company_assignments.reload.map(&:company_id) }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.fetch("error")).to eq("User not found")
    end
  end
end
