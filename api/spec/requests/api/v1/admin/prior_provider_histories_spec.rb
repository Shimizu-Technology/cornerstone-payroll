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

  it "retains provider check references separately from Cornerstone checks and exposes document gaps early" do
    employee = @employees.first
    EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: @admin)
    get "/api/v1/admin/prior_provider_histories"
    expect(response.parsed_body.fetch("readiness_gaps").map { |gap| gap["employee_id"] }).to eq([ employee.id, employee.id ])
    @payload["periods"].first["paychecks"].first["provider_payment_reference"] = "000708"
    original_sequence = @company.reload.next_check_number
    onboarding = convert_history(@company, @admin, @payload)
    get "/api/v1/admin/prior_provider_histories"
    expect(response.parsed_body.dig("onboardings", 0, "payment_references")).to include(
      hash_including("employee_id" => employee.id, "reference" => "000708")
    )
    check = onboarding.historical_import_batch.historical_paychecks.find_by!(employee: employee)
    expect(check.check_number).to be_nil
    expect(@company.reload.next_check_number).to eq(original_sequence)
    activate_history(onboarding, @admin)
    result = ImportedPayPeriodQuery.new(company_id: @company.id, id: check.historical_pay_period_id, params: {}).call
    expect(result.data.fetch(:paychecks)).to include(hash_including(provider_payment_reference: "000708", check_number: nil))
    client_result = ImportedPayPeriodQuery.new(company_id: @company.id, id: check.historical_pay_period_id, params: {}, audience: :client).call
    expect(client_result.data.fetch(:paychecks).map { |row| row[:provider_payment_reference] }).to all(be_nil)
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
    put "/api/v1/admin/prior_provider_histories/draft", params: { payload: @payload, step: 1, lock_version: version }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to include("removed")
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

  it "blocks real lifecycle and every native print/report path for retired and restored paid-source runs without financial effects" do
    ActiveJob::Base.queue_adapter = :test
    onboarding = convert_history(@company, @admin, @payload)
    activate_history(onboarding, @admin)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user) { @admin }
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id) { @company.id }
    run = @runs.first
    effects = lambda do
      {
        next_check_number: @company.reload.next_check_number,
        items: run.payroll_items.order(:id).map(&:attributes),
        employee_ytd: EmployeeYtdTotal.where(employee_id: @employees.map(&:id)).order(:id).map(&:attributes),
        company_ytd: CompanyYtdTotal.where(company: @company).order(:id).map(&:attributes),
        postings: PayrollLiabilityPosting.where(company: @company).count,
        entries: PayrollLiabilityEntry.count, loans: LoanTransaction.count,
        deposits: Form500Filing.where(company: @company).count,
        nonemployee_checks: NonEmployeeCheck.where(company: @company).count,
        jobs: ActiveJob::Base.queue_adapter.enqueued_jobs.size,
        emails: ActionMailer::Base.deliveries.size
      }
    end
    %w[retired_history calculated].each do |status|
      reverse_history(onboarding, @admin) if status == "calculated"
      expect(run.reload.status).to eq(status)
      before = effects.call
      lifecycle = PayPeriodLifecycleService.new(pay_period: run, actor: @admin)
      expect { lifecycle.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /already paid/)
      expect { lifecycle.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /already paid/)
      %w[transmittal_preview payroll_register payroll_register_csv payroll_register_pdf payroll_register_xlsx payroll_summary_by_employee_pdf full_print_package_pdf].each do |report|
        get "/api/v1/admin/reports/#{report}", params: { pay_period_id: run.id }
        expect(response).to have_http_status(:unprocessable_entity), "#{status} #{report}: #{response.body}"
        expect(response.parsed_body["error"]).to include("already paid")
      end
      post "/api/v1/admin/reports/transmittal_log_pdf", params: { pay_period_id: run.id }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(run.reload.transmittal).to be_nil
      expect(run.status).to eq(status)
      expect(effects.call).to eq(before)
    end
    expect(@employees).to all(satisfy { |employee| employee.reload.ytd_totals_before(year: 2026, pay_date: Date.new(2027, 1, 1), pay_period_id: 0)[:gross_pay].zero? })
  end

  it "audits successful source-file downloads with identity and batch context, but never logs a failed download as successful" do
    onboarding = convert_history(@company, @admin, @payload)
    file = onboarding.historical_import_batch.historical_import_source_files.first
    path = "/api/v1/admin/prior_provider_histories/#{onboarding.id}/source_files/#{file.id}"
    2.times { get path; expect(response).to have_http_status(:ok) }
    events = AuditLog.where(action: "prior_provider_histories#source_file", record_id: file.id).order(:id)
    expect(events.count).to eq(2)
    expect(events.last).to have_attributes(user_id: @admin.id, company_id: @company.id, record_type: "historical_import_source_files")
    expect(events.last.metadata).to include("prior_provider_history_onboarding_id" => onboarding.id,
      "historical_import_batch_id" => onboarding.historical_import_batch_id, "sha256" => file.sha256)
    R2StorageService.new.delete(file.storage_key)
    get path
    expect(response).to have_http_status(:unprocessable_entity)
    expect(events.count).to eq(2)
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
