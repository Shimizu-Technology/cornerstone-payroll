require "rails_helper"

RSpec.describe "Api::V1::Admin::Users", type: :request do
  let!(:company) { create(:company, name: "Staff HQ") }
  let!(:client_company) { create(:company, name: "Client A") }
  let!(:other_company) { create(:company, name: "Client B") }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "users-admin@example.com",
      name: "Users Admin",
      role: "admin",
      active: true
    )
  end
  let!(:managed_user) do
    User.create!(
      company: company,
      email: "accountant@example.com",
      name: "Accountant User",
      role: "accountant",
      active: true
    )
  end
  let!(:assignment) { CompanyAssignment.create!(user: managed_user, company: client_company) }
  let!(:switched_company_user) do
    User.create!(
      company: other_company,
      email: "other-company-user@example.com",
      name: "Other Company User",
      role: "accountant",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(admin_user.id)
  end

  describe "GET /api/v1/admin/users" do
    it "includes assigned company ids for listed users" do
      get "/api/v1/admin/users"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      managed_payload = data.find { |row| row.fetch("id") == managed_user.id }

      expect(managed_payload).to include("assigned_company_ids" => [client_company.id])
    end

    it "keeps super admins scoped to their staff company" do
      admin_user.update!(super_admin: true)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_company_id).and_return(other_company.id)

      get "/api/v1/admin/users"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      expect(data.map { |row| row.fetch("id") }).to match_array([admin_user.id, managed_user.id])
      expect(data.map { |row| row.fetch("id") }).not_to include(switched_company_user.id)
    end
  end
end
