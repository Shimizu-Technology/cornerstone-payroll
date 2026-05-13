# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::Organizations", type: :request do
  let!(:platform_org) { create(:organization, name: "Platform Org") }
  let!(:platform_company) { create(:company, organization: platform_org, name: "Platform HQ") }
  let!(:super_admin) do
    create(
      :user,
      organization: platform_org,
      company: platform_company,
      role: "super_admin",
      email: "platform-admin@example.com",
      name: "Platform Admin"
    )
  end
  let!(:org_admin) do
    create(
      :user,
      organization: platform_org,
      company: platform_company,
      role: "admin",
      email: "org-admin@example.com",
      name: "Org Admin"
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::OrganizationsController).to receive(:current_user).and_return(super_admin)
    allow_any_instance_of(Api::V1::Admin::OrganizationsController).to receive(:current_user_id).and_return(super_admin.id)
  end

  describe "GET /api/v1/admin/organizations" do
    it "lists organizations for super admins" do
      create(:organization, name: "Second Firm")

      get "/api/v1/admin/organizations"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("meta")).to include(
        "page" => 1,
        "per_page" => 50,
        "total_count" => 2,
        "total_pages" => 1
      )
      names = response.parsed_body.fetch("data").map { |row| row.fetch("name") }
      expect(names).to include("Platform Org", "Second Firm")
    end

    it "rejects org admins" do
      allow_any_instance_of(Api::V1::Admin::OrganizationsController).to receive(:current_user).and_return(org_admin)
      allow_any_instance_of(Api::V1::Admin::OrganizationsController).to receive(:current_user_id).and_return(org_admin.id)

      get "/api/v1/admin/organizations"

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Super admin access required")
    end
  end

  describe "POST /api/v1/admin/organizations" do
    before do
      allow_any_instance_of(Api::V1::Admin::OrganizationsController)
        .to receive(:invite_user)
        .and_return({ success: false, error: "Clerk API not configured" })
    end

    it "creates an organization, primary company, and first org admin" do
      expect {
        post "/api/v1/admin/organizations",
          params: {
            organization: {
              name: "Acme Guam CPAs",
              primary_company_name: "Acme Payroll HQ",
              admin: {
                email: "owner@acme.example",
                name: "Acme Owner"
              }
            }
          }
      }.to change(Organization, :count).by(1)
        .and change(Company, :count).by(1)
        .and change(User, :count).by(1)

      expect(response).to have_http_status(:created)
      organization = Organization.find_by!(slug: "acme-guam-cpas")
      company = organization.companies.find_by!(name: "Acme Payroll HQ")
      admin = User.find_by!(email: "owner@acme.example")

      expect(organization).to have_attributes(
        primary_company_id: company.id,
        client_limit: 3
      )
      expect(admin).to have_attributes(
        organization_id: organization.id,
        company_id: company.id,
        role: "org_admin",
        invitation_status: "pending"
      )
      expect(response.parsed_body.fetch("data")).to include(
        "name" => "Acme Guam CPAs",
        "companies_count" => 1,
        "client_limit" => 3,
        "unlimited_clients" => false,
        "users_count" => 1
      )
      expect(response.parsed_body.dig("data", "org_admins")).to contain_exactly(
        include("email" => "owner@acme.example", "role" => "org_admin")
      )
      expect(response.parsed_body.fetch("admin_user")).to include(
        "email" => "owner@acme.example",
        "role" => "org_admin"
      )
    end

    it "returns validation errors without partial org creation" do
      expect {
        post "/api/v1/admin/organizations",
          params: {
            organization: {
              name: "",
              primary_company_name: "Invalid HQ",
              admin: {
                email: "bad@example.com",
                name: "Bad Admin"
              }
            }
          }
      }.not_to change(Organization, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Name can't be blank")
    end
  end

  describe "PATCH /api/v1/admin/organizations/:id" do
    it "updates organization metadata" do
      patch "/api/v1/admin/organizations/#{platform_org.id}",
        params: {
          organization: {
            name: "Platform Organization",
            status: "inactive",
            unlimited_clients: true
          }
        }

      expect(response).to have_http_status(:ok)
      expect(platform_org.reload).to have_attributes(
        name: "Platform Organization",
        status: "inactive",
        client_limit: nil
      )
    end

    it "updates a finite client limit" do
      patch "/api/v1/admin/organizations/#{platform_org.id}",
        params: {
          organization: {
            client_limit: 8
          }
        }

      expect(response).to have_http_status(:ok)
      expect(platform_org.reload.client_limit).to eq(8)
      expect(response.parsed_body.fetch("data")).to include(
        "client_limit" => 8,
        "unlimited_clients" => false
      )
    end
  end

  describe "POST /api/v1/admin/organizations/:id/admin_users" do
    before do
      allow_any_instance_of(Api::V1::Admin::OrganizationsController)
        .to receive(:invite_user)
        .and_return({ success: false, error: "Clerk API not configured" })
    end

    it "creates an additional org admin in the target organization's primary company" do
      secondary_company = create(:company, organization: platform_org, name: "Secondary Client")
      platform_org.update!(primary_company: secondary_company)

      expect {
        post "/api/v1/admin/organizations/#{platform_org.id}/admin_users",
          params: {
            user: {
              email: "second-admin@example.com",
              name: "Second Admin"
            }
          }
      }.to change(User, :count).by(1)

      expect(response).to have_http_status(:created)
      created = User.find_by!(email: "second-admin@example.com")
      expect(created).to have_attributes(
        organization_id: platform_org.id,
        company_id: secondary_company.id,
        role: "org_admin"
      )
    end
  end
end
