# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scoped own AIRE account connection", type: :request do
  let(:home) { create(:company) }
  let(:company) { create(:company, organization: home.organization) }
  let(:actor) { create(:user, company: home, organization: home.organization, role: "accountant") }
  let!(:assignment) { create(:company_assignment, user: actor, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", shared_secret: "synthetic-source-secret") }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:path) { "/api/v1/admin/time_tracking_sources/#{source.id}/aire_account_link" }

  before do
    source
    allow_any_instance_of(Api::V1::Admin::TimeTrackingSourcesController).to receive(:current_user) { User.find(actor.id) }
    allow_any_instance_of(Api::V1::Admin::TimeTrackingSourcesController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::TimeTrackingSourcesController).to receive(:current_company).and_return(company)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("FRONTEND_URL").and_return("https://payroll.example.test/")
    allow(TimeTracking::Client).to receive(:new).and_return(client)
    allow(client).to receive(:payroll_account_link).and_return("account_link" => { "connected" => false })
    allow(client).to receive(:create_payroll_account_link_session).and_return(
      "authorization_url" => "https://aire.example.test/admin/payroll-link?token=synthetic-request",
      "expires_at" => 10.minutes.from_now.iso8601)
    allow(client).to receive(:disconnect_payroll_account_link).and_return("account_link" => { "connected" => false })
  end

  it "allows an assigned accountant to read and connect only their own identity with the new return page" do
    get path, params: { external_actor_id: actor.id + 100, user_id: actor.id + 100 }
    expect(response).to have_http_status(:ok)
    expect(client).to have_received(:payroll_account_link).with(external_actor_id: actor.id)

    before_state = source.attributes
    post path, params: { external_actor_id: actor.id + 100, external_actor_email: "other@example.test",
      user_id: actor.id + 100, base_url: "https://other.example.test", shared_secret: "must-not-be-saved" }
    expect(response).to have_http_status(:created)
    expect(client).to have_received(:create_payroll_account_link_session).with(
      external_actor_id: actor.id, external_actor_email: actor.email,
      return_url: "https://payroll.example.test/app/time-account-connection?source_id=#{source.id}")
    expect(source.reload.attributes).to eq(before_state)
    expect(StaffRolePolicy.capabilities_for(actor)).to include("manage_own_aire_account_link")
    expect(StaffRolePolicy.capabilities_for(actor)).not_to include("manage_client_configuration", "manage_organization")
  end

  it "disconnects the accountant's own link and legacy fallback without touching another operator" do
    own = create(:time_tracking_delegation, company: company, time_tracking_source: source, user: actor)
    other = create(:user, company: company, organization: company.organization, role: "manager")
    other_delegation = create(:time_tracking_delegation, company: company, time_tracking_source: source, user: other)
    delete path, params: { external_actor_id: other.id, user_id: other.id }
    expect(response).to have_http_status(:ok)
    expect(client).to have_received(:disconnect_payroll_account_link).with(external_actor_id: actor.id)
    expect(TimeTrackingDelegation.exists?(own.id)).to be(false)
    expect(other_delegation.reload).to be_persisted
    expect(AuditLog.last).to have_attributes(user_id: actor.id, company_id: company.id, action: "time_tracking_delegation#removed")
  end

  it "keeps source and token configuration unavailable to an accountant" do
    before_state = source.attributes
    put "/api/v1/admin/time_tracking_sources/#{source.id}", params: {
      time_tracking_source: { base_url: "https://other.example.test", shared_secret: "must-not-be-saved" }
    }
    expect(response).to have_http_status(:forbidden)
    put "/api/v1/admin/time_tracking_sources/#{source.id}/delegation", params: { delegation_token: "must-not-be-saved" }
    expect(response).to have_http_status(:forbidden)
    delete "/api/v1/admin/time_tracking_sources/#{source.id}/delegation"
    expect(response).to have_http_status(:forbidden)
    expect(source.reload.attributes).to eq(before_state)
    expect(TimeTrackingDelegation.count).to eq(0)
    expect(TimeTracking::Client).not_to have_received(:new)
  end

  it "allows the assigned accountant to read source metadata without raw integration credentials" do
    get "/api/v1/admin/time_tracking_sources"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("time_tracking_sources").map { |s| s.fetch("id") }).to eq([ source.id ])
    expect(response.body).not_to include("synthetic-source-secret")
    get "/api/v1/admin/time_tracking_sources/#{source.id}"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("time_tracking_source", "shared_secret_configured")).to be(true)
    expect(response.body).not_to include("synthetic-source-secret")
  end

  {
    "unassigned accountant" => -> { assignment.destroy! },
    "expired assignment" => -> { assignment.update!(expires_at: 1.minute.ago) },
    "inactive actor" => -> { actor.update!(active: false) },
    "inactive company" => -> { company.update!(active: false) },
    "archived workspace" => -> { company.update_columns(test_workspace_archived_at: Time.current) },
    "inactive organization" => -> { company.organization.update!(status: "inactive") },
    "client" => -> { actor.update!(role: "client") },
    "employee" => -> { actor.update!(role: "employee") },
    "wrong tenant" => -> { actor.update_columns(organization_id: create(:organization).id) }
  }.each do |label, setup|
    it "denies #{label} status, create and disconnect without side effects" do
      instance_exec(&setup)
      state = source.reload.attributes
      audit_count = AuditLog.count
      get path
      expect(response).to have_http_status(:forbidden)
      post path
      expect(response).to have_http_status(:forbidden)
      delete path
      expect(response).to have_http_status(:forbidden)
      expect(source.reload.attributes).to eq(state)
      expect(AuditLog.count).to eq(audit_count)
      expect(TimeTracking::Client).not_to have_received(:new)
    end
  end

  it "rejects a source in another company before constructing a remote client" do
    other_source = create(:time_tracking_source, source_type: "aire_services")
    other_path = "/api/v1/admin/time_tracking_sources/#{other_source.id}/aire_account_link"
    get other_path
    expect(response).to have_http_status(:not_found)
    post other_path
    expect(response).to have_http_status(:not_found)
    delete other_path
    expect(response).to have_http_status(:not_found)
    expect(TimeTracking::Client).not_to have_received(:new)
  end

  it "rejects the inactive previous source after replacement without blind own-link requests" do
    source.update!(active: false)
    create(:time_tracking_source, company: company, source_type: "aire_services")
    state = source.reload.attributes
    get path
    expect(response).to have_http_status(:unprocessable_entity)
    post path
    expect(response).to have_http_status(:unprocessable_entity)
    delete path
    expect(response).to have_http_status(:unprocessable_entity)
    expect(source.reload.attributes).to eq(state)
    expect(TimeTracking::Client).not_to have_received(:new)
  end

  it "rejects missing integration credentials without asking the accountant to configure them" do
    source.update_columns(shared_secret: nil)
    get path
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("configured by your payroll administrator")
    post path
    expect(response).to have_http_status(:unprocessable_entity)
    delete path
    expect(response).to have_http_status(:unprocessable_entity)
    expect(TimeTracking::Client).not_to have_received(:new)
  end

  context "read-only workspace reviewer" do
    let(:company) do
      create(:company, organization: home.organization, payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "training_replay", migration_source_company: home, migration_rehearsal_status: "ready")
    end
    let!(:assignment) { create(:company_assignment, user: actor, company: company, workspace_access_level: "reviewer") }

    it "cannot use connection status or commands that require workspace write access" do
      get path
      expect(response).to have_http_status(:forbidden)
      post path
      expect(response).to have_http_status(:forbidden)
      delete path
      expect(response).to have_http_status(:forbidden)
      expect(TimeTracking::Client).not_to have_received(:new)
    end
  end
end
