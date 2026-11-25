# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Auth", type: :request do
  describe "POST /api/v1/cable_ticket" do
    before do
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    end

    it "returns a short-lived cable ticket for the current company" do
      company = create(:company)
      user = create(:user, company: company, role: "admin")
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

      post "/api/v1/cable_ticket"

      expect(response).to have_http_status(:created)
      ticket = response.parsed_body.fetch("ticket")
      expect(ticket).to be_present
      expect(CableTicketService.consume(ticket)).to include("user_id" => user.id, "company_id" => company.id)
    end
  end

  describe "GET /api/v1/auth/me" do
    before do
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    end

    it "returns unauthorized when no current user exists" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(nil)

      get "/api/v1/auth/me"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("Not authenticated")
    end

    it "returns current user data when available" do
      company = create(:company)
      user = User.create!(
        company: company,
        email: "auth-test-#{company.id}@example.com",
        name: "Auth Test User",
        role: "admin",
        active: true
      )
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

      get "/api/v1/auth/me"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("user")).to include(
        "id" => user.id,
        "role" => "admin",
        "home_company_id" => company.id,
        "assigned_company_ids" => [ company.id ],
        "capabilities" => include(
          "use_printer_profiles",
          "manage_printer_profile_library",
          "manage_client_check_settings",
          "view_record_activity"
        )
      )
      expect(response.parsed_body.fetch("user")).not_to have_key("super_admin")
      expect(response.parsed_body.fetch("features")).to eq(
        "offering" => "payroll_service",
        "hours_source" => "manual",
        "intake_adapter" => nil,
        "client_portal_enabled" => false,
        "employee_portal_enabled" => false,
        "subdomain_enabled" => false,
        "time_module_enabled" => false
      )
    end

    it "returns the persisted operating profile summary in features on /auth/me rather than legacy fallback" do
      # Legacy columns would resolve to payroll_service / manual / client_portal_enabled: false.
      company = create(:company, payroll_intake_source_types: [], client_payroll_approval_required: false)
      ClientOperatingProfile.create!(
        company: company,
        effective_on: Date.new(2026, 1, 1),
        ends_on: nil,
        version: 1,
        offering: "payroll_portals",
        hours_source: "intake_adapter",
        intake_adapter: "mosa_revel",
        client_portal_enabled: true,
        employee_portal_enabled: false,
        # The time module stays locked until Milestone 6, so it can't be stored on.
        options: {}
      )
      user = create(:user, company: company, organization: company.organization, role: "admin")
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

      get "/api/v1/auth/me"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("features")).to eq(
        "offering" => "payroll_portals",
        "hours_source" => "intake_adapter",
        "intake_adapter" => "mosa_revel",
        "client_portal_enabled" => true,
        "employee_portal_enabled" => false,
        "subdomain_enabled" => false,
        "time_module_enabled" => false
      )
    end

    it "returns features for a client user and switches features for multi-company staff via X-Company-Id" do
      organization = create(:organization)
      company_a = create(:company, organization: organization, name: "Client A")
      company_b = create(:company, organization: organization, name: "Client B")

      ClientOperatingProfile.create!(
        company: company_a,
        effective_on: Date.new(2026, 1, 1),
        version: 1,
        offering: "payroll_service",
        hours_source: "intake_adapter",
        intake_adapter: "spike_email",
        client_portal_enabled: true,
        employee_portal_enabled: false
      )
      ClientOperatingProfile.create!(
        company: company_b,
        effective_on: Date.new(2026, 1, 1),
        version: 1,
        offering: "workforce_suite",
        hours_source: "connected_app",
        client_portal_enabled: false,
        employee_portal_enabled: false
      )

      client_user = create(:user, organization: organization, company: company_a, role: "client", active: true)
      create(:company_assignment, user: client_user, company: company_a)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      get "/api/v1/auth/me"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("user", "company_id")).to eq(company_a.id)
      expect(response.parsed_body.fetch("features")).to include(
        "offering" => "payroll_service",
        "hours_source" => "intake_adapter",
        "intake_adapter" => "spike_email",
        "client_portal_enabled" => true
      )

      staff_user = create(:user, organization: organization, company: company_a, role: "accountant", active: true)
      create(:company_assignment, user: staff_user, company: company_a)
      create(:company_assignment, user: staff_user, company: company_b)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(staff_user)

      get "/api/v1/auth/me", headers: { "X-Company-Id" => company_b.id.to_s }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("user", "company_id")).to eq(company_b.id)
      expect(response.parsed_body.fetch("features")).to include(
        "offering" => "workforce_suite",
        "hours_source" => "connected_app",
        "intake_adapter" => nil,
        "client_portal_enabled" => false
      )
    end

    it "omits unauthorized home company metadata and features for a client whose grants expired" do
      organization = create(:organization)
      home_company = create(:company, organization: organization, name: "Secret Home Co")
      ClientOperatingProfile.create!(
        company: home_company,
        effective_on: Date.new(2026, 1, 1),
        version: 1,
        offering: "payroll_portals",
        hours_source: "manual",
        client_portal_enabled: true,
        employee_portal_enabled: true
      )
      client_user = create(:user, organization: organization, company: home_company, role: "client", active: true)
      create(:company_assignment, user: client_user, company: home_company, expires_at: 1.minute.ago)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)

      get "/api/v1/auth/me"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("user")).to include(
        "company_id" => nil,
        "company_name" => nil,
        "home_company_id" => nil,
        "assigned_company_ids" => []
      )
      expect(response.parsed_body.fetch("features")).to be_nil
    end

    it "exposes own AIRE account connection to accountants without configuration access" do
      company = create(:company)
      user = create(:user, company: company, organization: company.organization, role: "accountant")
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
      get "/api/v1/auth/me"
      expect(response).to have_http_status(:ok)
      capabilities = response.parsed_body.dig("user", "capabilities")
      expect(capabilities).to include("manage_own_aire_account_link", "payroll_operations")
      expect(capabilities).not_to include("manage_client_configuration", "manage_organization")
    end

    it "retains identity without substituting an active client for an inaccessible header" do
      organization = create(:organization)
      company = create(:company, organization: organization)
      foreign_company = create(:company)
      user = User.create!(
        company: company,
        organization: organization,
        email: "auth-org-scope@example.com",
        name: "Auth Org Scope",
        role: "admin",
        active: true
      )
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

      get "/api/v1/auth/me", headers: { "X-Company-Id" => foreign_company.id.to_s }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("user")).to include(
        "organization_id" => organization.id,
        "organization_name" => organization.name,
        "company_id" => nil,
        "home_company_id" => company.id
      )
      expect(response.parsed_body.fetch("features")).to be_nil
    end
  end
end
