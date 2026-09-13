# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::TimeTrackingSources", type: :request do
  let(:company) { create(:company) }

  def authenticate_as(user)
    allow_any_instance_of(Api::V1::Admin::TimeTrackingSourcesController)
      .to receive(:current_user).and_return(user)
    allow_any_instance_of(Api::V1::Admin::TimeTrackingSourcesController)
      .to receive(:current_company_id).and_return(company.id)
  end

  it "allows organization administrators to list integration configuration" do
    authenticate_as(create(:user, company: company, role: "admin"))

    get "/api/v1/admin/time_tracking_sources"

    expect(response).to have_http_status(:ok)
  end

  it "allows accountants to read the non-secret source metadata needed by the import modal" do
    authenticate_as(create(:user, company: company, role: "accountant"))

    get "/api/v1/admin/time_tracking_sources"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("time_tracking_sources" => [])
  end

  it "denies managers access to integration configuration" do
    authenticate_as(create(:user, company: company, role: "manager"))

    post "/api/v1/admin/time_tracking_sources", params: {
      time_tracking_source: {
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "must-not-be-saved"
      }
    }

    expect(response).to have_http_status(:forbidden)
    expect(TimeTrackingSource).not_to exist
  end

  it "stores a different encrypted AIRE delegation for each authorized operator without exposing it" do
    manager = create(:user, company: company, organization: company.organization, role: "manager")
    admin = create(:user, company: company, organization: company.organization, role: "admin")
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    authenticate_as(manager)

    put "/api/v1/admin/time_tracking_sources/#{source.id}/delegation", params: { delegation_token: "manager-token" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("time_tracking_source", "delegation_token_configured")).to be(true)
    expect(response.body).not_to include("manager-token")
    expect(source.delegation_for(manager).token).to eq("manager-token")
    expect(AuditLog.order(:id).last).to have_attributes(
      action: "time_tracking_delegation#saved",
      user_id: manager.id,
      company_id: company.id
    )

    authenticate_as(admin)
    get "/api/v1/admin/time_tracking_sources/#{source.id}"
    expect(response.parsed_body.dig("time_tracking_source", "delegation_token_configured")).to be(false)
  end

  it "lets an operator remove only their own AIRE delegation" do
    manager = create(:user, company: company, organization: company.organization, role: "manager")
    administrator = create(:user, company: company, organization: company.organization, role: "admin")
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    create(:time_tracking_delegation, company: company, time_tracking_source: source, user: manager)
    administrator_delegation = create(
      :time_tracking_delegation,
      company: company,
      time_tracking_source: source,
      user: administrator
    )
    authenticate_as(manager)

    delete "/api/v1/admin/time_tracking_sources/#{source.id}/delegation"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("time_tracking_source", "delegation_token_configured")).to be(false)
    expect(source.delegation_for(manager)).to be_nil
    expect(administrator_delegation.reload).to be_persisted
    expect(AuditLog.order(:id).last).to have_attributes(
      action: "time_tracking_delegation#removed",
      user_id: manager.id,
      company_id: company.id
    )
  end

  it "rejects delegated access for non-AIRE sources" do
    manager = create(:user, company: company, organization: company.organization, role: "manager")
    source = create(:time_tracking_source, company: company, source_type: "custom")
    authenticate_as(manager)

    put "/api/v1/admin/time_tracking_sources/#{source.id}/delegation", params: { delegation_token: "wrong-source" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).not_to include("wrong-source")
    expect(TimeTrackingDelegation).not_to exist
  end

  it "keeps a successful source connection result when the optional cockpit probe is unavailable" do
    authenticate_as(create(:user, company: company, role: "admin"))
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:time_summary).and_return(
      "source" => "aire_services",
      "generated_at" => Time.current.iso8601,
      "employees" => [],
      "summary" => {}
    )
    allow(client).to receive(:payroll_cockpit_employees).and_raise(
      TimeTracking::Client::Error,
      "Cockpit endpoint is unavailable"
    )

    post "/api/v1/admin/time_tracking_sources/#{source.id}/test_connection"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("ok" => true, "cockpit_ready" => false)
  end
end
