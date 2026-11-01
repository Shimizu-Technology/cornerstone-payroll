# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PriorProviderHistories", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 11, 2, 2)) { example.run } }

  before do
    @company, @admin, @employees, @runs, @payload = history_fixture(period_count: 1)
    @accountant = create(:user, company: @company, organization: @company.organization, role: "accountant")
    @actor = @admin
    allow_any_instance_of(Api::V1::Admin::PriorProviderHistoriesController).to receive(:current_user) { @actor }
    allow_any_instance_of(Api::V1::Admin::PriorProviderHistoriesController).to receive(:current_company_id) { @selected_company_id || @company.id }
  end

  after do
    HistoricalImportSourceFile.where(company: @company).find_each { |file| R2StorageService.new.delete(file.storage_key) }
  end

  it "lets accountants inspect history while denying conversion, preview, activation and reversal" do
    @actor = @accountant
    get "/api/v1/admin/prior_provider_histories"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["can_manage"]).to be(false)
    expect(response.parsed_body["candidates"].size).to eq(1)
    post "/api/v1/admin/prior_provider_histories/preview", params: { payload: @payload }, as: :json
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/prior_provider_histories", params: { payload: @payload }, as: :json
    expect(response).to have_http_status(:forbidden)
    onboarding = convert_history(@company, @admin, @payload)
    post "/api/v1/admin/prior_provider_histories/#{onboarding.id}/activate", params: { acknowledgement: PriorProviderHistory::Activation::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/prior_provider_histories/#{onboarding.id}/reverse", params: { reason: "Test", acknowledgement: PriorProviderHistory::Reversal::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:forbidden)
  end

  it "provides the complete preview, upload, atomic conversion, activation and reversal API" do
    post "/api/v1/admin/prior_provider_histories/preview", params: { payload: @payload }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body["ready"]).to be(true), response.body
    digest = response.parsed_body.fetch("digest")
    post "/api/v1/admin/prior_provider_histories", params: { payload: JSON.generate(@payload), preview_digest: digest,
      idempotency_key: "request-contract-2026", files: [ history_upload ], acknowledgement: PriorProviderHistory::Conversion::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:created), response.body
    id = response.parsed_body.dig("onboarding", "id")
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user) { @admin }
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id) { @company.id }
    get "/api/v1/admin/reports/transmittal_preview", params: { pay_period_id: @runs.first.id }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("already paid")
    post "/api/v1/admin/reports/transmittal_log_pdf", params: { pay_period_id: @runs.first.id }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(@runs.first.transmittal).to be_nil
    post "/api/v1/admin/prior_provider_histories/#{id}/activate", params: { acknowledgement: PriorProviderHistory::Activation::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("onboarding", "status")).to eq("active")
    get "/api/v1/admin/prior_provider_histories"
    expect(response.parsed_body["candidates"]).to be_empty
    expect(response.parsed_body["onboardings"].first["employee_balances"].size).to eq(3)
    post "/api/v1/admin/prior_provider_histories/#{id}/reverse", params: { reason: "New source evidence", acknowledgement: PriorProviderHistory::Reversal::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("onboarding", "status")).to eq("reversed")
  end

  it "hides foreign-company onboarding records and rechecks revoked permissions inside services" do
    onboarding = convert_history(@company, @admin, @payload)
    @selected_company_id = create(:company, organization: @company.organization).id
    post "/api/v1/admin/prior_provider_histories/#{onboarding.id}/activate", params: { acknowledgement: PriorProviderHistory::Activation::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:forbidden)
    @admin.update!(role: "accountant")
    expect { activate_history(onboarding, @admin) }.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized)
  end
  it "honors a current accountant client-management grant and rejects it after expiry" do
    assignment = CompanyAssignment.find_or_initialize_by(user: @accountant, company: @company)
    assignment.assign_attributes(client_management: true, granted_by: @admin)
    assignment.save!
    @actor = @accountant
    get "/api/v1/admin/prior_provider_histories"
    expect(response.parsed_body["can_manage"]).to be(true)
    post "/api/v1/admin/prior_provider_histories/preview", params: { payload: @payload }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["ready"]).to be(true)
    onboarding = convert_history(@company, @accountant, @payload)
    assignment.update!(expires_at: 1.minute.ago)
    expect { activate_history(onboarding, @accountant) }.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized)
    expect(onboarding.reload.status).to eq("converted")
  end
  it "reports candidate overflow instead of claiming a truncated list is complete" do
    scope = @company.pay_periods.calculated
    allow(scope).to receive(:where).and_return(scope)
    allow(scope).to receive(:count).and_return(61)
    allow(@company).to receive(:pay_periods).and_return(double(calculated: scope))
    allow_any_instance_of(Api::V1::Admin::PriorProviderHistoriesController).to receive(:current_company).and_return(@company)
    get "/api/v1/admin/prior_provider_histories"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("eligible_run_count" => 61, "candidates_overflow" => true)
  end

end
