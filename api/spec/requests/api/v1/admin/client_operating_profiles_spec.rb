# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::ClientOperatingProfiles", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  include EmployeeLifecyclePr4Helpers

  let(:organization) { create(:organization) }
  let(:company) do
    create(
      :company,
      organization: organization,
      name: "MoSa's Joint",
      client_payroll_approval_required: true,
      payroll_intake_source_types: [ "mosa_revel" ]
    )
  end
  let(:other_company) { create(:company, organization: organization, name: "Spike Coffee") }
  let(:foreign_company) { create(:company, name: "Foreign Org Client") }

  let!(:v1) do
    ClientOperatingProfile.create!(
      company: company,
      effective_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 6, 30),
      version: 1,
      offering: "payroll_service",
      hours_source: "manual",
      client_portal_enabled: false,
      employee_portal_enabled: false,
      options: { "tips" => { "default" => "paid_in_check" } },
      reason: "Initial baseline"
    )
  end

  let!(:v2) do
    ClientOperatingProfile.create!(
      company: company,
      effective_on: Date.new(2026, 7, 1),
      ends_on: nil,
      version: 2,
      offering: "payroll_portals",
      hours_source: "intake_adapter",
      intake_adapter: "mosa_revel",
      client_portal_enabled: true,
      employee_portal_enabled: false,
      options: {
        "tips" => { "default" => "paid_in_check" },
        "overtime" => { "mode" => "source_reports" },
        "workweek" => { "alignment" => "warn_if_offset" }
      },
      reason: "Enabled Revel intake and client portal"
    )
  end

  def sign_in_as(user)
    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(user.id)
  end

  it "lets an administrator cancel an activation that never took effect, even after payroll advances" do
    unlock_lifecycle_mode!
    org_admin = create(:user, organization: organization, company: company, role: "org_admin")
    sign_in_as(org_admin)
    v2.update!(options: v2.options.deep_merge("client_portal" => { "employee_lifecycle_mode" => "client_managed" }),
      lifecycle_mode_activation_failed_at: Time.current,
      lifecycle_mode_activation_blockers: { "qualifying_staff_notification_recipients_count" => 0 })
    path = "/api/v1/admin/companies/#{company.id}/operating_profile"

    get path
    expect(response.parsed_body.dig("employee_lifecycle_preflight", "lifecycle_mode_activation_status")).to eq("blocked")
    expect(response.parsed_body.fetch("available_effective_dates")).not_to include(v2.effective_on.iso8601)

    patch path, params: {
      effective_on: v2.effective_on.iso8601, lock_version: v2.lock_version,
      reason: "Keep existing approvals for this client.",
      changes: { "client_portal.employee_lifecycle_mode" => "approval_first" }
    }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(v2.reload.lifecycle_mode_activation_failed_at).to be_nil
    expect(v2.option_value("client_portal.employee_lifecycle_mode")).to eq("approval_first")
  end

  describe "GET /api/v1/admin/companies/:company_id/operating_profile" do
    it "returns effective profile, version history, full catalog, and all editable keys for an org_admin" do
      org_admin = create(:user, organization: organization, company: company, role: "org_admin")
      sign_in_as(org_admin)

      get "/api/v1/admin/companies/#{company.id}/operating_profile"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.fetch("as_of")).to eq(PayrollBusinessClock.today.iso8601)
      expect(body.fetch("effective")).to include(
        "id" => v2.id,
        "version" => 2,
        "offering" => "payroll_portals",
        "hours_source" => "intake_adapter",
        "intake_adapter" => "mosa_revel",
        "client_portal_enabled" => true,
        "employee_portal_enabled" => false,
        "persisted" => true
      )
      expect(body.dig("effective", "options", "subdomain_enabled")).to be(false)
      expect(body.dig("effective", "options", "time_module_enabled")).to be(false)
      expect(body.fetch("history").map { |row| row.fetch("version") }).to eq([ 2, 1 ])
      expect(body.fetch("catalog").map { |entry| entry.fetch("id") }).to eq(OperatingProfileCatalog.ids)
      expect(body.fetch("editable_keys")).to eq(OperatingProfileCatalog.ids)
    end

    it "resolves a historical version when ?on= is provided and rejects invalid dates with 422" do
      admin = create(:user, organization: organization, company: company, role: "admin")
      sign_in_as(admin)

      get "/api/v1/admin/companies/#{company.id}/operating_profile", params: { on: "2026-03-15" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("as_of")).to eq("2026-03-15")
      expect(response.parsed_body.fetch("effective")).to include(
        "id" => v1.id,
        "version" => 1,
        "offering" => "payroll_service",
        "hours_source" => "manual",
        "client_portal_enabled" => false
      )
      expect(response.parsed_body.fetch("history").length).to eq(2)

      get "/api/v1/admin/companies/#{company.id}/operating_profile", params: { on: "not-a-date" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Invalid date parameter")
    end

    it "scopes editable_keys by StaffRolePolicy capability for managers and accountants" do
      manager = create(:user, organization: organization, company: company, role: "manager")
      create(:company_assignment, user: manager, company: company)
      sign_in_as(manager)

      get "/api/v1/admin/companies/#{company.id}/operating_profile"
      expect(response).to have_http_status(:ok)
      manager_keys = response.parsed_body.fetch("editable_keys")
      expect(manager_keys).to include("offering", "client_portal_enabled", "tips.default", "year_end.kind_of_employer")
      expect(manager_keys).not_to include("hours_source", "intake_adapter", "subdomain_enabled", "time_module_enabled")

      accountant = create(:user, organization: organization, company: company, role: "accountant")
      assignment = create(:company_assignment, user: accountant, company: company)
      sign_in_as(accountant)

      get "/api/v1/admin/companies/#{company.id}/operating_profile"
      expect(response).to have_http_status(:ok)
      accountant_keys = response.parsed_body.fetch("editable_keys")
      expect(accountant_keys).to contain_exactly(
        "year_end.kind_of_employer",
        "year_end.contact.name",
        "year_end.contact.phone",
        "year_end.contact.email"
      )

      # Delegated client_management grants client administration & configuration keys, never organization keys.
      admin = create(:user, organization: organization, company: company, role: "admin")
      assignment.update!(client_management: true, granted_by: admin)

      get "/api/v1/admin/companies/#{company.id}/operating_profile"
      expect(response).to have_http_status(:ok)
      delegated_keys = response.parsed_body.fetch("editable_keys")
      expect(delegated_keys).to include("offering", "client_portal_enabled", "tips.default", "year_end.kind_of_employer")
      expect(delegated_keys).not_to include("hours_source", "intake_adapter", "subdomain_enabled", "time_module_enabled")
    end

    it "forbids client and legacy employee roles from reading admin operating profiles" do
      %w[client employee].each do |role|
        user = create(:user, organization: organization, company: company, role: role)
        sign_in_as(user)

        get "/api/v1/admin/companies/#{company.id}/operating_profile"
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "forbids staff from reading unassigned or foreign-organization companies and returns 404 for missing companies" do
      accountant = create(:user, organization: organization, company: company, role: "accountant")
      create(:company_assignment, user: accountant, company: company)
      sign_in_as(accountant)

      get "/api/v1/admin/companies/#{other_company.id}/operating_profile"
      expect(response).to have_http_status(:forbidden)

      admin = create(:user, organization: organization, company: company, role: "admin")
      sign_in_as(admin)

      get "/api/v1/admin/companies/#{foreign_company.id}/operating_profile"
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/admin/companies/99999999/operating_profile"
      expect(response).to have_http_status(:not_found)
    end

    it "returns 403 when X-Company-Id differs from the path company and allows matching header" do
      admin = create(:user, organization: organization, company: company, role: "admin")
      sign_in_as(admin)

      get "/api/v1/admin/companies/#{company.id}/operating_profile",
          headers: { "X-Company-Id" => other_company.id.to_s }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to include("Company context does not match")

      get "/api/v1/admin/companies/#{company.id}/operating_profile",
          headers: { "X-Company-Id" => foreign_company.id.to_s }
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/admin/companies/#{company.id}/operating_profile",
          headers: { "X-Company-Id" => company.id.to_s }
      expect(response).to have_http_status(:ok)
    end

    it "selects the same Guam business-date version on /auth/me and admin GET across the UTC/Guam date boundary" do
      admin = create(:user, organization: organization, company: company, role: "admin")
      sign_in_as(admin)

      # 2026-06-30 16:00 UTC is 2026-06-30 in UTC but 2026-07-01 02:00 in Pacific/Guam.
      travel_to(Time.utc(2026, 6, 30, 16, 0, 0)) do
        get "/api/v1/admin/companies/#{company.id}/operating_profile"
        expect(response).to have_http_status(:ok)
        admin_body = response.parsed_body
        expect(admin_body.fetch("as_of")).to eq("2026-07-01")
        expect(admin_body.dig("effective", "version")).to eq(2)
        expect(admin_body.dig("effective", "offering")).to eq("payroll_portals")

        get "/api/v1/auth/me"
        expect(response).to have_http_status(:ok)
        auth_features = response.parsed_body.fetch("features")
        expect(auth_features).to include(
          "offering" => admin_body.dig("effective", "offering"),
          "hours_source" => admin_body.dig("effective", "hours_source"),
          "intake_adapter" => admin_body.dig("effective", "intake_adapter"),
          "client_portal_enabled" => admin_body.dig("effective", "client_portal_enabled")
        )
      end
    end

    it "enforces test workspace access policy, applies overrides to effective and history, and reports empty editable_keys on read-only test workspaces" do
      admin = create(:user, organization: organization, company: company, role: "admin")
      accountant = create(:user, organization: organization, company: company, role: "accountant")
      create(:company_assignment, user: accountant, company: company)
      workspace = create(
        :company,
        organization: organization,
        name: "MoSa's Sealed Backup",
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "backup_snapshot",
        test_workspace_sealed_at: Time.current,
        migration_source_company: company,
        migration_rehearsal_status: "ready"
      )
      ClientOperatingProfile.create!(
        company: workspace,
        effective_on: Date.new(2026, 1, 1),
        ends_on: Date.new(2026, 6, 30),
        version: 1,
        offering: "payroll_portals",
        hours_source: "manual",
        client_portal_enabled: true,
        employee_portal_enabled: true,
        options: { "subdomain_enabled" => true }
      )
      ClientOperatingProfile.create!(
        company: workspace,
        effective_on: Date.new(2026, 7, 1),
        ends_on: nil,
        version: 2,
        offering: "payroll_portals",
        hours_source: "intake_adapter",
        intake_adapter: "mosa_revel",
        client_portal_enabled: true,
        employee_portal_enabled: true,
        options: { "subdomain_enabled" => true }
      )

      sign_in_as(accountant)
      get "/api/v1/admin/companies/#{workspace.id}/operating_profile"
      expect(response).to have_http_status(:forbidden)

      sign_in_as(admin)
      get "/api/v1/admin/companies/#{workspace.id}/operating_profile"
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.fetch("editable_keys")).to eq([])
      expect(body.dig("effective", "employee_portal_enabled")).to be(false)
      expect(body.dig("effective", "options", "subdomain_enabled")).to be(false)
      expect(body.fetch("history").length).to eq(2)
      body.fetch("history").each do |row|
        expect(row.fetch("employee_portal_enabled")).to be(false)
        expect(row.dig("options", "subdomain_enabled")).to be(false)
      end
    end
  end
end
