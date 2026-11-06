# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Protected time tracking health", type: :request do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, role: "accountant") }
  let(:source) { create(:time_tracking_source, company: company, active: false) }
  before do
    allow_any_instance_of(Api::V1::Admin::TimeTrackingSourceHealthController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::TimeTrackingSourceHealthController).to receive(:current_company_id).and_return(company.id)
  end
  it "allows assigned payroll operators to read cached local evidence without managing credentials" do
    get "/api/v1/admin/time_tracking_sources/#{source.id}/health"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("source_id" => source.id, "company_id" => company.id)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).not_to match(/shared_secret|test-shared-secret|base_url|delegation|email/)
  end
  it "does not allow a foreign company source" do
    foreign = create(:time_tracking_source)
    get "/api/v1/admin/time_tracking_sources/#{foreign.id}/health"
    expect(response).to have_http_status(:not_found)
  end
  it "rejects client users" do
    actor.update!(role: "client")
    get "/api/v1/admin/time_tracking_sources/#{source.id}/health"
    expect(response).to have_http_status(:forbidden)
  end
  it "still enforces assigned company access for payroll operators" do
    foreign_actor = create(:user, company: create(:company), role: "accountant")
    allow_any_instance_of(Api::V1::Admin::TimeTrackingSourceHealthController).to receive(:current_user).and_return(foreign_actor)
    get "/api/v1/admin/time_tracking_sources/#{source.id}/health"
    expect(response).to have_http_status(:forbidden)
  end
end
