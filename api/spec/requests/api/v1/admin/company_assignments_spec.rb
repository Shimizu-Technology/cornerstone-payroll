# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::CompanyAssignments", type: :request do
  let!(:staff_company) { create(:company, name: "Staff HQ") }
  let!(:client_company) { create(:company, name: "Accessible Client") }
  let!(:other_company) { create(:company, name: "Foreign Client") }

  let!(:admin_user) do
    User.create!(
      company: staff_company,
      email: "assignment-admin@example.com",
      name: "Assignment Admin",
      role: "admin",
      active: true
    )
  end

  let!(:managed_user) do
    User.create!(
      company: staff_company,
      email: "assignment-user@example.com",
      name: "Managed User",
      role: "accountant",
      active: true
    )
  end

  let!(:foreign_staff_company) { create(:company, name: "Foreign Staff HQ") }
  let!(:foreign_user) do
    User.create!(
      company: foreign_staff_company,
      email: "foreign-assignment-user@example.com",
      name: "Foreign User",
      role: "admin",
      active: true
    )
  end

  let!(:admin_access_assignment) { CompanyAssignment.create!(user: admin_user, company: client_company) }
  let!(:managed_assignment) { CompanyAssignment.create!(user: managed_user, company: client_company) }
  let!(:foreign_assignment) { CompanyAssignment.create!(user: foreign_user, company: other_company) }

  describe "GET /api/v1/admin/company_assignments" do
    it "does not leak assignments for users in other staff companies" do
      get "/api/v1/admin/company_assignments", params: { user_id: managed_user.id }

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      expect(data.map { |row| row.fetch("id") }).to eq([managed_assignment.id])
      expect(data.map { |row| row.fetch("user_id") }).not_to include(foreign_user.id)
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
    it "rejects inaccessible company ids" do
      put "/api/v1/admin/company_assignments/bulk_update",
        params: { user_id: managed_user.id, company_ids: [other_company.id] }

      expect(response).to have_http_status(:forbidden)
      expect(managed_user.company_assignments.reload.map(&:company_id)).to eq([client_company.id])
    end
  end
end
