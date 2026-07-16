require "rails_helper"

RSpec.describe "Api::V1::Admin::Users", type: :request do
  let!(:organization) { create(:organization, name: "Staff Firm") }
  let!(:company) { create(:company, organization: organization, name: "Staff HQ") }
  let!(:client_company) { create(:company, organization: organization, name: "Client A") }
  let!(:other_company) { create(:company, organization: organization, name: "Client B") }
  let!(:foreign_organization) { create(:organization, name: "Foreign Firm") }
  let!(:foreign_company) { create(:company, organization: foreign_organization, name: "Foreign Client") }
  let!(:admin_user) do
    User.create!(
      company: company,
      organization: organization,
      email: "users-admin@example.com",
      name: "Users Admin",
      role: "admin",
      active: true
    )
  end
  let!(:managed_user) do
    User.create!(
      company: company,
      organization: organization,
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
      organization: organization,
      email: "other-company-user@example.com",
      name: "Other Company User",
      role: "accountant",
      active: true
    )
  end
  let!(:manager_user) do
    User.create!(
      company: company,
      organization: organization,
      email: "manager@example.com",
      name: "Manager User",
      role: "manager",
      active: true
    )
  end
  let!(:super_admin_user) do
    User.create!(
      company: company,
      organization: organization,
      email: "users-super-admin@example.com",
      name: "Users Super Admin",
      role: "super_admin",
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

    it "does not expose users from another organization" do
      foreign_user = User.create!(
        company: foreign_company,
        organization: foreign_organization,
        email: "foreign-user@example.com",
        name: "Foreign User",
        role: "admin",
        active: true
      )

      get "/api/v1/admin/users"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch("data")
      expect(data.map { |row| row.fetch("id") }).not_to include(foreign_user.id)
    end
  end

  describe "authorization" do
    it "returns 403 for manager users because user management is admin-only" do
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(manager_user)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(manager_user.id)

      get "/api/v1/admin/users"

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Admin access required")
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
      audit = AuditLog.find_by!(action: "users#created", record_id: created_user.id)
      expect(audit).to have_attributes(subject_name: "New Accountant", actor_name: admin_user.name, organization_id: organization.id)
      expect(audit.metadata.fetch("after_values")).to include("email" => "new-accountant@example.com", "role" => "accountant")
    end

    it "returns validation errors without persisting a user" do
      expect {
        post "/api/v1/admin/users",
          params: {
            user: {
              email: "",
              name: "Invalid User",
              role: "accountant",
              company_ids: [client_company.id]
            }
          }
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Email can't be blank")
    end

    it "prevents organization admins from creating platform super admins" do
      expect {
        post "/api/v1/admin/users",
          params: {
            user: {
              email: "platform-admin@example.com",
              name: "Platform Admin",
              role: "super_admin"
            }
          }
      }.not_to change(User, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Cannot assign that role")
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
      audit = AuditLog.find_by!(action: "users#updated", record_id: managed_user.id)
      expect(audit.metadata.fetch("changed_fields")).to include("name", "role", "assigned_company_ids")
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

    it "allows non-assignment edits for users in another staff workspace without mutating existing assignments" do
      CompanyAssignment.create!(user: switched_company_user, company: client_company)

      patch "/api/v1/admin/users/#{switched_company_user.id}",
        params: {
          user: {
            name: "Renamed Other Company User",
            role: "accountant"
          }
        }

      expect(response).to have_http_status(:ok)
      switched_company_user.reload
      expect(switched_company_user.name).to eq("Renamed Other Company User")
      expect(switched_company_user.role).to eq("accountant")
      expect(switched_company_user.company_assignments.pluck(:company_id)).to eq([client_company.id])
    end

    it "allows assignment changes for users in another staff workspace" do
      patch "/api/v1/admin/users/#{switched_company_user.id}",
        params: {
          user: {
            name: "Renamed Other Company User",
            role: "accountant",
            company_ids: [client_company.id]
          }
        }

      expect(response).to have_http_status(:ok)
      switched_company_user.reload
      expect(switched_company_user.name).to eq("Renamed Other Company User")
      expect(switched_company_user.company_assignments.pluck(:company_id)).to eq([client_company.id])
    end

    it "allows role changes for users in another staff workspace when the change would clear assignments" do
      CompanyAssignment.create!(user: switched_company_user, company: client_company)

      patch "/api/v1/admin/users/#{switched_company_user.id}",
        params: {
          user: {
            name: "Renamed Other Company User",
            role: "employee"
          }
        }

      expect(response).to have_http_status(:ok)
      switched_company_user.reload
      expect(switched_company_user.name).to eq("Renamed Other Company User")
      expect(switched_company_user.role).to eq("employee")
      expect(switched_company_user.company_assignments).to be_empty
    end

    it "does not let a colocated super admin satisfy the last organization admin guard" do
      super_admin = User.create!(
        company: company,
        organization: organization,
        email: "platform-peer@example.com",
        name: "Platform Peer",
        role: "super_admin",
        active: true
      )
      expect(super_admin).to be_present
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(super_admin)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(super_admin.id)

      patch "/api/v1/admin/users/#{admin_user.id}",
        params: {
          user: {
            role: "manager"
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Cannot demote the last active admin")
      expect(admin_user.reload.role).to eq("admin")
    end

    it "rejects assignment changes outside the admin's accessible companies" do
      patch "/api/v1/admin/users/#{managed_user.id}",
        params: {
          user: {
            role: "accountant",
            company_ids: [foreign_company.id]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("One or more companies are not accessible")
      expect(managed_user.reload.company_assignments.pluck(:company_id)).to eq([client_company.id])
    end

    it "prevents super admins from saving cross-organization client assignments" do
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(super_admin_user)
      allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(super_admin_user.id)

      patch "/api/v1/admin/users/#{managed_user.id}",
        params: {
          user: {
            role: "accountant",
            company_ids: [foreign_company.id]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Company must belong to the user's organization")
      expect(managed_user.reload.company_assignments.pluck(:company_id)).to eq([client_company.id])
    end
  end

  describe "DELETE /api/v1/admin/users/:id" do
    it "deletes the user while preserving historical records that reference them" do
      document = create(:client_document, company: client_company, uploaded_by: managed_user)
      invitation = UserInvitation.create!(
        company: client_company,
        invited_by: managed_user,
        email: "pending-client@example.com",
        name: "Pending Client",
        role: "client",
        token: SecureRandom.hex(16),
        invited_at: Time.current,
        expires_at: 7.days.from_now
      )
      change_request = EmployeeChangeRequest.create!(
        company: client_company,
        employee: create(:employee, company: client_company),
        requested_by: managed_user,
        proposed_changes: { "phone" => "671-555-0101" },
        original_values: {},
        direct_changes_applied: {}
      )

      expect {
        delete "/api/v1/admin/users/#{managed_user.id}", params: { user: {} }
      }.to change(User, :count).by(-1)

      expect(response).to have_http_status(:no_content)
      expect(document.reload.uploaded_by_id).to be_nil
      expect(invitation.reload.invited_by_id).to be_nil
      expect(change_request.reload.requested_by_id).to be_nil
    end
  end
end
