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
    allow_any_instance_of(Api::V1::Admin::UsersController)
      .to receive(:create_clerk_invitation)
      .and_return({ success: false, error: "Clerk API not configured" })
  end

  describe "GET /api/v1/admin/users" do
    it "includes assigned company ids and company summaries for listed users" do
      get "/api/v1/admin/users"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      managed_payload = data.find { |row| row.fetch("id") == managed_user.id }

      expect(managed_payload).to include("assigned_company_ids" => [client_company.id])
      expect(managed_payload.fetch("assigned_companies")).to include(
        include(
          "id" => client_company.id,
          "name" => client_company.name
        )
      )
    end

    it "admins see all users regardless of selected company" do
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_company_id).and_return(other_company.id)

      get "/api/v1/admin/users"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      expect(data.map { |row| row.fetch("id") }).to include(admin_user.id, managed_user.id, switched_company_user.id)
    end
  end

  describe "POST /api/v1/admin/users" do
    it "creates a user and saves client assignments in the same request" do
      expect {
        post "/api/v1/admin/users",
          params: {
            user: {
              email: "new-accountant@example.com",
              name: "New Accountant",
              role: "accountant",
              company_ids: [client_company.id, other_company.id]
            }
          }
      }.to change(User, :count).by(1)
        .and change(CompanyAssignment, :count).by(2)

      expect(response).to have_http_status(:created)
      payload = response.parsed_body.fetch("data")
      created_user = User.find(payload.fetch("id"))

      expect(created_user.company_assignments.order(:company_id).pluck(:company_id)).to eq([client_company.id, other_company.id])
      expect(payload.fetch("assigned_company_ids")).to match_array([client_company.id, other_company.id])
      expect(payload.fetch("assigned_companies")).to match_array([
        include("id" => client_company.id, "name" => client_company.name),
        include("id" => other_company.id, "name" => other_company.name)
      ])
    end
  end

  describe "PATCH /api/v1/admin/users/:id" do
    it "updates role and client assignments together" do
      patch "/api/v1/admin/users/#{managed_user.id}",
        params: {
          user: {
            name: "Updated Accountant",
            role: "manager",
            company_ids: [other_company.id]
          }
        }

      expect(response).to have_http_status(:ok)
      managed_user.reload
      expect(managed_user.name).to eq("Updated Accountant")
      expect(managed_user.role).to eq("manager")
      expect(managed_user.company_assignments.pluck(:company_id)).to eq([other_company.id])

      payload = response.parsed_body.fetch("data")
      expect(payload.fetch("assigned_company_ids")).to eq([other_company.id])
      expect(payload.fetch("assigned_companies")).to eq([
        {
          "id" => other_company.id,
          "name" => other_company.name
        }
      ])
    end

    it "clears stale client assignments when the role no longer uses them" do
      patch "/api/v1/admin/users/#{managed_user.id}",
        params: {
          user: {
            role: "employee"
          }
        }

      expect(response).to have_http_status(:ok)
      managed_user.reload
      expect(managed_user.role).to eq("employee")
      expect(managed_user.company_assignments).to be_empty

      payload = response.parsed_body.fetch("data")
      expect(payload).not_to have_key("assigned_company_ids")
      expect(payload).not_to have_key("assigned_companies")
    end

    it "allows non-assignment edits for users in another staff workspace when assignments are unchanged" do
      patch "/api/v1/admin/users/#{switched_company_user.id}",
        params: {
          user: {
            name: "Renamed Other Company User",
            role: "accountant",
            company_ids: []
          }
        }

      expect(response).to have_http_status(:ok)
      switched_company_user.reload
      expect(switched_company_user.name).to eq("Renamed Other Company User")
      expect(switched_company_user.role).to eq("accountant")
      expect(switched_company_user.company_assignments).to be_empty
    end

    it "rejects assignment changes for users in another staff workspace" do
      patch "/api/v1/admin/users/#{switched_company_user.id}",
        params: {
          user: {
            name: "Renamed Other Company User",
            role: "accountant",
            company_ids: [client_company.id]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Client assignments can only be edited for users in your staff workspace")

      switched_company_user.reload
      expect(switched_company_user.name).to eq("Other Company User")
      expect(switched_company_user.company_assignments).to be_empty
    end
  end
end
