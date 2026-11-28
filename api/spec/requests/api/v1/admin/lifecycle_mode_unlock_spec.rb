# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client-managed employee lifecycle unlock", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:organization) { create(:organization, name: "Synthetic Practice") }
  let!(:company_no_profile) { create(:company, organization: organization, name: "Harbor Baseline Co") }
  let!(:company_portal) { create(:company, organization: organization, name: "Lagoon Trade Co") }
  let!(:company_legacy_review) { create(:company, organization: organization, name: "Coral Bakery Co") }
  let!(:org_admin) do
    create(:user, company: company_portal, organization: organization, role: "org_admin",
      name: "Alex Admin", email: "alex.unlock@example.test")
  end
  let!(:manager) do
    create(:user, company: company_portal, organization: organization, role: "manager",
      name: "Dana Manager", email: "dana.unlock@example.test")
  end
  let!(:client_manager) do
    create(:user, company: company_portal, organization: organization, role: "client",
      name: "Sloane Client", email: "sloane.unlock@example.test")
  end
  let(:today) { Date.new(2026, 11, 20) }

  before do
    [ company_no_profile, company_portal, company_legacy_review ].each do |target|
      CompanyAssignment.create!(user: org_admin, company: target)
      CompanyAssignment.create!(user: manager, company: target)
    end
    CompanyAssignment.create!(user: client_manager, company: company_portal)

    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company_portal, effective_on: Date.new(2026, 1, 1))
        .merge(client_portal_enabled: true)
    )
    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company_legacy_review, effective_on: Date.new(2026, 1, 1))
        .merge(
          client_portal_enabled: true,
          options: { "client_portal" => { "review_first" => { "profile" => true, "pay" => true } } }
        )
    )

    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:current_user) { @acting_user || org_admin }
    allow_any_instance_of(ApplicationController).to receive(:current_user_id) { (@acting_user || org_admin).id }
    allow_any_instance_of(Api::V1::Client::BaseController).to receive(:current_company_id).and_return(company_portal.id)
    allow_any_instance_of(Api::V1::Client::BaseController).to receive(:current_company).and_return(company_portal)
  end

  it "removes the lock from catalog and CompanyFeatures while keeping every existing company approval_first" do
    expect(OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES).not_to have_key("client_portal.employee_lifecycle_mode")
    expect(OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS).not_to include("client_portal.employee_lifecycle_mode")
    expect(OperatingProfileCatalog.locked_keys).not_to include("client_portal.employee_lifecycle_mode")
    expect(CompanyFeatures::LOCKED_OFF).not_to include("client_portal.employee_lifecycle_mode")
    expect(OperatingProfileCatalog.fetch("client_portal.employee_lifecycle_mode").as_json[:locked_until_milestone]).to be_nil

    [ company_no_profile, company_portal, company_legacy_review ].each do |target|
      features = CompanyFeatures.for(target, on: today)
      expect(features.employee_lifecycle_mode).to eq("approval_first")
      expect(features.client_managed_employee_lifecycle?).to be(false)
    end
  end

  it "enforces mode-change capability and all preflights before switching, without any lock stubbing" do
    create(:pay_period, company: company_portal, status: "draft",
      start_date: today - 14, end_date: today - 1, pay_date: today + 4)

    travel_to(Time.utc(2026, 11, 20, 12)) do
      # Manager lacks :manage_organization and cannot switch lifecycle mode.
      @acting_user = manager
      get "/api/v1/admin/companies/#{company_portal.id}/operating_profile"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("locked_keys")).not_to include("client_portal.employee_lifecycle_mode")
      expect(response.parsed_body.fetch("editable_keys")).not_to include("client_portal.employee_lifecycle_mode")
      expect(response.parsed_body.fetch("employee_lifecycle_preflight")).to include("ready" => false)

      patch "/api/v1/admin/companies/#{company_portal.id}/operating_profile", params: {
        effective_on: (today - 14).iso8601,
        lock_version: 0,
        reason: "Manager attempting mode switch",
        changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
      }, as: :json
      expect(response).to have_http_status(:forbidden)

      # Org admin sees the unlocked, editable control, but is blocked until preflights clear.
      @acting_user = org_admin
      get "/api/v1/admin/companies/#{company_portal.id}/operating_profile"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("editable_keys")).to include("client_portal.employee_lifecycle_mode")

      patch "/api/v1/admin/companies/#{company_portal.id}/operating_profile", params: {
        effective_on: (today - 14).iso8601,
        lock_version: 0,
        reason: "Attempt switch without staff recipients",
        changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("error")).to include("staff notification recipient")
      expect(CompanyFeatures.for(company_portal, on: today).employee_lifecycle_mode).to eq("approval_first")

      # Once a qualifying staff recipient is added, switching succeeds and activates immediately.
      PortalNotificationRecipient.create!(company: company_portal, user: manager, team_role: "lead", added_by: org_admin)
      patch "/api/v1/admin/companies/#{company_portal.id}/operating_profile", params: {
        effective_on: (today - 14).iso8601,
        lock_version: 0,
        reason: "Enable client-managed mode after preflights pass",
        changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(CompanyFeatures.for(company_portal, on: today).employee_lifecycle_mode).to eq("client_managed")
      # Other companies remain approval_first.
      expect(CompanyFeatures.for(company_no_profile, on: today).employee_lifecycle_mode).to eq("approval_first")
      expect(CompanyFeatures.for(company_legacy_review, on: today).employee_lifecycle_mode).to eq("approval_first")
    end
  end

  it "runs ActivateScheduledLifecycleModesJob to activate a due future-dated switch without stubbing" do
    future_date = today + 14
    create(:pay_period, company: company_portal, status: "draft",
      start_date: future_date, end_date: future_date + 13, pay_date: future_date + 19)
    PortalNotificationRecipient.create!(company: company_portal, user: manager, team_role: "lead", added_by: org_admin)

    travel_to(Time.utc(2026, 11, 20, 12)) do
      patch "/api/v1/admin/companies/#{company_portal.id}/operating_profile", params: {
        effective_on: future_date.iso8601,
        lock_version: 0,
        reason: "Schedule client-managed mode for next pay period",
        changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
      }, as: :json
      expect(response).to have_http_status(:ok), response.body
      scheduled = company_portal.client_operating_profiles.history_order.first
      expect(scheduled.effective_on).to eq(future_date)
      expect(scheduled.lifecycle_mode_activated_at).to be_nil
      expect(CompanyFeatures.for(company_portal, on: today).employee_lifecycle_mode).to eq("approval_first")
    end

    travel_to(Time.utc(2026, 12, 4, 12)) do
      # Still approval_first until the activation job runs.
      expect(CompanyFeatures.for(company_portal, on: future_date).employee_lifecycle_mode).to eq("approval_first")

      ActivateScheduledLifecycleModesJob.perform_now(as_of: future_date.iso8601)

      expect(CompanyFeatures.for(company_portal, on: future_date).employee_lifecycle_mode).to eq("client_managed")
      expect(company_portal.client_operating_profiles.history_order.first.lifecycle_mode_activated_at).to be_present
      expect(CompanyFeatures.for(company_legacy_review, on: future_date).employee_lifecycle_mode).to eq("approval_first")
    end
  end

  it "leaves approval_first client employee workflows unchanged for companies that have not switched" do
    @acting_user = client_manager
    worker = create(:employee, :hourly, company: company_portal, first_name: "Casey", last_name: "Baseline", pay_rate: 18.0)

    expect do
      post "/api/v1/client/employees", params: {
        employee: {
          first_name: "Morgan",
          last_name: "Baseline",
          employment_type: "hourly",
          pay_rate: 17.50,
          filing_status: "single",
          ssn: "900-11-4455",
          ssn_confirmation: "900-11-4455",
          hire_date: "2026-10-01",
          w4_effective_on: "2026-10-01",
          address_line1: "200 Baseline Lane",
          city: "Tamuning",
          state: "GU",
          zip: "96913"
        }
      }, as: :json
    end.to change(EmployeeChangeRequest, :count).by(1).and change(EmployeeVerificationItem, :count).by(0)
    expect(response).to have_http_status(:created)
    expect(Employee.order(:id).last).to have_attributes(status: "inactive", portal_pending_approval: true, readiness_gate_enforced: false)

    expect do
      patch "/api/v1/client/employees/#{worker.id}", params: { employee: { pay_rate: 21.0 } }, as: :json
    end.to change(EmployeeChangeRequest, :count).by(1).and change(EmployeeVerificationItem, :count).by(0)
    expect(worker.reload.pay_rate).to eq(18.0)

    post "/api/v1/client/employees/#{worker.id}/terminate", params: {
      termination: { effective_date: "2026-11-15", last_worked_on: "2026-11-15", reason_category: "voluntary" }
    }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["code"]).to eq("client_lifecycle_disabled")
  end
end
