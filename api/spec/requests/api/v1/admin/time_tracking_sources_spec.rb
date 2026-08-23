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
end
