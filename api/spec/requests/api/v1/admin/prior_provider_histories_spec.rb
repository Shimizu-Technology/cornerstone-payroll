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

  def grant_access(user, company = @company)
    CompanyAssignment.create!(user: user, company: company, granted_by: @admin)
  end

  it "lets an accountant who runs this client's payroll record, activate and reverse history end to end" do
    grant_access(@accountant)
    @actor = @accountant
    get "/api/v1/admin/prior_provider_histories"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("can_manage" => true)
    expect(response.parsed_body["employees"].map { |row| row["ssn_last_four"] }).to eq(@employees.sort_by(&:last_name).map(&:ssn_last_four))
    put "/api/v1/admin/prior_provider_histories/draft", params: { payload: @payload, step: 1 }, as: :json
    expect(response).to have_http_status(:ok), response.body
    post "/api/v1/admin/prior_provider_histories/preview", params: { payload: @payload }, as: :json
    expect(response.parsed_body["ready"]).to be(true), response.body
    post "/api/v1/admin/prior_provider_histories", params: { payload: JSON.generate(@payload), preview_digest: response.parsed_body.fetch("digest"),
      idempotency_key: "accountant-history-2026", files: [ history_upload ], acknowledgement: PriorProviderHistory::Conversion::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:created), response.body
    id = response.parsed_body.dig("onboarding", "id")
    expect(PriorProviderHistoryOnboarding.find(id).created_by).to eq(@accountant)
    expect(PriorProviderHistoryDraft.where(company: @company)).to be_empty
    totals = response.parsed_body.dig("onboarding", "employee_totals")
    expect(totals.size).to eq(3)
    expect(totals.map { |row| row["gross_pay"].to_d }).to all(eq(2_000))
    post "/api/v1/admin/prior_provider_histories/#{id}/activate", params: { acknowledgement: PriorProviderHistory::Activation::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:ok), response.body
    expect(PriorProviderHistoryOnboarding.find(id).activated_by).to eq(@accountant)
    post "/api/v1/admin/prior_provider_histories/#{id}/reverse", params: { reason: "Provider sent a corrected register", acknowledgement: PriorProviderHistory::Reversal::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("onboarding", "status")).to eq("reversed")
  end

  it "denies client and employee roles and staff without access to the client" do
    other = create(:company, organization: @company.organization)
    outsider = create(:user, company: other, organization: @company.organization, role: "accountant")
    grant_access(outsider, other)
    client = create(:user, company: @company, organization: @company.organization, role: "client")
    employee_user = create(:user, company: @company, organization: @company.organization, role: "employee")
    onboarding = convert_history(@company, @admin, @payload)
    [ outsider, client, employee_user ].each do |user|
      @actor = user
      get "/api/v1/admin/prior_provider_histories"
      expect(response).to have_http_status(:forbidden), "#{user.role}: #{response.body}"
      post "/api/v1/admin/prior_provider_histories/preview", params: { payload: @payload }, as: :json
      expect(response).to have_http_status(:forbidden)
      put "/api/v1/admin/prior_provider_histories/draft", params: { payload: @payload, step: 1 }, as: :json
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/admin/prior_provider_histories/#{onboarding.id}/activate", params: { acknowledgement: PriorProviderHistory::Activation::ACKNOWLEDGEMENT }
      expect(response).to have_http_status(:forbidden)
      expect { activate_history(onboarding, user) }.to raise_error(PriorProviderHistory::Authorization::NotAuthorized)
    end
    expect(onboarding.reload.status).to eq("converted")
  end

  it "saves a shared resumable draft and refuses a stale overwrite" do
    grant_access(@accountant)
    @actor = @accountant
    put "/api/v1/admin/prior_provider_histories/draft", params: { payload: @payload, step: 2 }, as: :json
    version = response.parsed_body.dig("draft", "lock_version")
    @actor = @admin
    get "/api/v1/admin/prior_provider_histories"
    expect(response.parsed_body["draft"]).to include("step" => 2, "updated_by_name" => @accountant.name, "lock_version" => version)
    expect(response.parsed_body.dig("draft", "payload", "periods").size).to eq(1)
    put "/api/v1/admin/prior_provider_histories/draft", params: { payload: @payload.merge("provider_name" => "Admin edit"), step: 2, lock_version: version }, as: :json
    expect(response).to have_http_status(:ok)
    @actor = @accountant
    put "/api/v1/admin/prior_provider_histories/draft", params: { payload: @payload, step: 1, lock_version: version }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to include(@admin.name)
    expect(PriorProviderHistoryDraft.find_by!(company: @company).payload["provider_name"]).to eq("Admin edit")
    delete "/api/v1/admin/prior_provider_histories/draft"
    expect(response).to have_http_status(:no_content)
    expect(PriorProviderHistoryDraft.where(company: @company)).to be_empty
  end

  it "turns on historical payroll for the client when history is recorded" do
    @company.update!(historical_payroll_enabled: false)
    onboarding = convert_history(@company, @admin, @payload)
    expect(@company.reload.historical_payroll_enabled).to be(true)
    expect(AuditLog.find_by!(action: "prior_provider_history#convert", record_id: onboarding.id).metadata).to include("enabled_historical_payroll" => true)
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
    get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: @runs.first.id }
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

  it "hides foreign-company onboarding records and rechecks revoked access inside services" do
    home = create(:company, organization: @company.organization)
    assigned = create(:user, company: home, organization: @company.organization, role: "accountant")
    assignment = grant_access(assigned)
    onboarding = convert_history(@company, assigned, @payload)
    @actor = assigned
    @selected_company_id = create(:company, organization: @company.organization).id
    post "/api/v1/admin/prior_provider_histories/#{onboarding.id}/activate", params: { acknowledgement: PriorProviderHistory::Activation::ACKNOWLEDGEMENT }
    expect(response).to have_http_status(:forbidden)
    assignment.update!(expires_at: 1.minute.ago)
    expect { activate_history(onboarding, assigned) }.to raise_error(PriorProviderHistory::Authorization::NotAuthorized)
    @admin.update!(role: "client")
    expect { activate_history(onboarding, @admin) }.to raise_error(PriorProviderHistory::Authorization::NotAuthorized)
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
