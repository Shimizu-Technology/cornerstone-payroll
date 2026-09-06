# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::HistoricalImports", type: :request do
  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }

  before do
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_company_id).and_return(company.id)
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  after do
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  it "previews, paginates, applies, and locks a reconciled QuickBooks bundle" do
    post "/api/v1/admin/historical_imports/preview", params: { files: quickbooks_history_uploads }

    expect(response).to have_http_status(:ok), response.body
    preview_body = JSON.parse(response.body)
    batch_id = preview_body.dig("data", "id")
    expect(preview_body.dig("data", "preview_summary")).to include(
      "paycheck_count" => 2,
      "period_count" => 2
    )
    expect(preview_body.fetch("meta")).to eq("idempotent" => false)
    expect(preview_body.dig("data", "source_retention_summary")).to include(
      "expected_file_count" => 5,
      "retained_file_count" => 5,
      "verified_file_count" => 5,
      "failed_file_count" => 0,
      "ready" => true
    )
    expect(preview_body.dig("data", "source_files").size).to eq(5)
    expect(preview_body.to_json).not_to include("storage_key")
    expect(PayPeriod.count).to eq(0)
    expect(PayrollItem.count).to eq(0)

    post "/api/v1/admin/historical_imports/#{batch_id}/archive_unlinked_workers"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("meta", "reviewed_count")).to eq(3)
    expect(response.parsed_body.dig("data", "worker_review_summary", "needs_review")).to eq(0)

    get "/api/v1/admin/historical_imports/#{batch_id}", params: { per_page: 1, search: "Alice" }
    expect(response).to have_http_status(:ok)
    show_body = JSON.parse(response.body)
    expect(show_body.dig("data", "paychecks").sole).to include(
      "source_employee_name" => "Worker, Alice",
      "gross_pay" => "1000.0",
      "net_pay" => "725.0"
    )
    expect(show_body.dig("meta", "total_count")).to eq(1)

    post "/api/v1/admin/historical_imports/#{batch_id}/apply", params: { acknowledgement: "not accepted" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)).to include("details" => {})

    post "/api/v1/admin/historical_imports/#{batch_id}/apply", params: {
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "status")).to eq("applied")

    post "/api/v1/admin/historical_imports/#{batch_id}/lock"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Approve the verified QuickBooks cutover review")

    expect do
      post "/api/v1/admin/historical_imports/#{batch_id}/verify_cutover"
    end.to have_enqueued_job(QuickbooksHistory::CutoverVerificationJob).with(batch_id, admin.id, kind_of(String))
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "cutover_review", "status")).to eq("pending")
    expect(response.parsed_body.dig("meta", "enqueued")).to be(true)

    expect do
      post "/api/v1/admin/historical_imports/#{batch_id}/verify_cutover"
    end.not_to have_enqueued_job(QuickbooksHistory::CutoverVerificationJob)
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("meta", "enqueued")).to be(false)

    verification_started_at = HistoricalImportBatch.find(batch_id).historical_import_cutover_review.verification_started_at.iso8601(6)
    QuickbooksHistory::CutoverVerificationJob.perform_now(batch_id, admin.id, verification_started_at)
    get "/api/v1/admin/historical_imports/#{batch_id}"
    expect(response).to have_http_status(:ok)
    cutover = response.parsed_body.dig("data", "cutover_review")
    expect(cutover.dig("evidence", "checks")).to all(include("passed" => true))
    expect(cutover.to_json).not_to include("000-00-0001", "private_snapshot", "storage_key")

    patch "/api/v1/admin/historical_imports/#{batch_id}/update_cutover_review", params: {
      exception_dispositions: "not-an-object",
      attestations: [],
      approval_notes: "Invalid request shape."
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("exception_dispositions must be an object")

    patch "/api/v1/admin/historical_imports/#{batch_id}/update_cutover_review", params: {
      exception_dispositions: {},
      attestations: [],
      approval_notes: "Invalid request shape."
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("attestations must be an object")

    dispositions = cutover.dig("evidence", "exceptions").to_h { |exception| [ exception.fetch("key"), "Accepted source limitation." ] }
    attestations = cutover.fetch("attestation_labels").keys.index_with(true)
    patch "/api/v1/admin/historical_imports/#{batch_id}/update_cutover_review", params: {
      exception_dispositions: dispositions.merge("unverified-client-key" => "Must not be persisted."),
      attestations: attestations,
      approval_notes: "No remaining limitations."
    }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("data", "cutover_review", "ready_for_approval")).to be(true)
    expect(response.parsed_body.dig("data", "cutover_review", "exception_dispositions")).not_to have_key("unverified-client-key")

    get "/api/v1/admin/historical_imports/#{batch_id}/download_cutover_evidence"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq(SpreadsheetReportExporter::CONTENT_TYPE)
    expect(response.body.byteslice(0, 2)).to eq("PK")

    post "/api/v1/admin/historical_imports/#{batch_id}/approve_cutover", params: {
      acknowledgement: HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT
    }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "cutover_review", "status")).to eq("approved")

    post "/api/v1/admin/historical_imports/#{batch_id}/lock"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "status")).to eq("locked")

    get "/api/v1/admin/historical_imports"
    expect(response).to have_http_status(:ok)
    index_body = JSON.parse(response.body)
    expect(index_body.dig("meta", "archive")).to include(
      "applied_batch_count" => 1,
      "paycheck_count" => 2,
      "gross_pay" => "3000.0",
      "net_pay" => "2325.0"
    )
    expect(index_body.fetch("meta")).to include("total_count" => 1, "current_page" => 1)
    expect(index_body.dig("data", 0, "cutover_review")).not_to have_key("evidence")

    get "/api/v1/admin/historical_imports/#{batch_id}"
    expect(response.parsed_body.dig("data", "cutover_review", "evidence", "version")).to eq(1)
  end

  it "filters and paginates historical import batches" do
    department = create(:department, company: company)
    create(
      :employee,
      company: company,
      department: department,
      first_name: "Alice",
      last_name: "Worker",
      ssn_encrypted: "000-00-0001"
    )
    imported = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
    beta = HistoricalImportBatch.create!(
      company: company,
      source_label: "Beta archive",
      bundle_digest: "beta-digest",
      importer_version: "test",
      status: "applied"
    )
    gamma = HistoricalImportBatch.create!(
      company: company,
      source_label: "Gamma archive",
      bundle_digest: "gamma-digest",
      importer_version: "test",
      status: "locked"
    )

    get "/api/v1/admin/historical_imports", params: { page: 2, per_page: 1 }
    page_body = JSON.parse(response.body)
    expect(response).to have_http_status(:ok)
    expect(page_body.dig("meta", "total_count")).to eq(3)
    expect(page_body.dig("meta", "current_page")).to eq(2)
    expect(page_body.fetch("data").size).to eq(1)

    get "/api/v1/admin/historical_imports", params: { search: "Beta", status: "applied" }
    expect(JSON.parse(response.body).fetch("data").sole.fetch("id")).to eq(beta.id)

    get "/api/v1/admin/historical_imports", params: { status: "locked" }
    expect(JSON.parse(response.body).fetch("data").sole.fetch("id")).to eq(gamma.id)

    get "/api/v1/admin/historical_imports", params: { department_id: department.id }
    expect(JSON.parse(response.body).fetch("data").sole.fetch("id")).to eq(imported.id)
  end

  it "lets accountants review history but not mutate imports" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_user).and_return(accountant)

    get "/api/v1/admin/historical_imports"
    expect(response).to have_http_status(:ok)

    post "/api/v1/admin/historical_imports/preview", params: { files: quickbooks_history_uploads }
    expect(response).to have_http_status(:forbidden)
    expect(HistoricalImportBatch.count).to eq(0)

    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
    post "/api/v1/admin/historical_imports/#{batch.id}/archive_unlinked_workers"
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/historical_imports/#{batch.id}/apply", params: {
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    }
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/historical_imports/#{batch.id}/lock"
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/historical_imports/#{batch.id}/verify_source_files"
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/historical_imports/#{batch.id}/verify_cutover"
    expect(response).to have_http_status(:forbidden)
    patch "/api/v1/admin/historical_imports/#{batch.id}/update_cutover_review"
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/historical_imports/#{batch.id}/approve_cutover"
    expect(response).to have_http_status(:forbidden)
    source_file = batch.historical_import_source_files.first
    get "/api/v1/admin/historical_imports/#{batch.id}/source_files/#{source_file.id}/download"
    expect(response).to have_http_status(:forbidden)
    expect(batch.reload).to be_previewed
  end

  it "verifies and downloads an exact retained source file for a manager or administrator" do
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
    source_file = batch.historical_import_source_files.in_manifest_order.first
    expected_bytes = R2StorageService.new.download(source_file.storage_key)

    post "/api/v1/admin/historical_imports/#{batch.id}/verify_source_files"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("meta", "all_verified")).to be(true)

    get "/api/v1/admin/historical_imports/#{batch.id}/source_files/#{source_file.id}/download"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/vnd.ms-excel")
    expect(response.headers.fetch("Content-Disposition")).to include(source_file.original_filename)
    expect(response.body).to eq(expected_bytes)
    expect(AuditLog.where(action: "historical_imports#download_source_file", record_id: source_file.id)).to exist
  end

  it "lets accountants download approved cutover evidence without granting source-file access" do
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
    review_historical_workers_as_archive_only(batch, actor: admin)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    review = QuickbooksHistory::CutoverVerificationService.new(batch: batch, actor: admin).call.review
    dispositions = review.evidence.fetch("exceptions").to_h do |exception|
      [ exception.fetch("key"), "Accepted after reviewing the reconciled source evidence." ]
    end
    review_service = QuickbooksHistory::CutoverReviewService.new(review: review, actor: admin)
    review_service.save!(
      exception_dispositions: dispositions,
      attestations: HistoricalImportCutoverReview::ATTESTATIONS.keys.index_with(true),
      approval_notes: "No remaining limitations."
    )

    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_user).and_return(accountant)

    get "/api/v1/admin/historical_imports/#{batch.id}/download_cutover_evidence"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to include("Approved cutover evidence")
    expect(response.parsed_body.fetch("details")).to eq({})
    expect(AuditLog.where(
      user: accountant,
      action: "historical_imports#download_cutover_evidence",
      record_id: review.id
    )).not_to exist

    review_service.approve!(acknowledgement: HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT)

    get "/api/v1/admin/historical_imports/#{batch.id}/download_cutover_evidence"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq(SpreadsheetReportExporter::CONTENT_TYPE)
    expect(response.body.byteslice(0, 2)).to eq("PK")
    expect(AuditLog.where(
      user: accountant,
      action: "historical_imports#download_cutover_evidence",
      record_id: review.id
    )).to exist
  end

  it "marks altered retained evidence as failed and blocks apply" do
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
    review_historical_workers_as_archive_only(batch, actor: admin)
    source_file = batch.historical_import_source_files.in_manifest_order.first
    R2StorageService.new.upload(source_file.storage_key, "altered", content_type: source_file.content_type)

    post "/api/v1/admin/historical_imports/#{batch.id}/verify_source_files"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("meta", "all_verified")).to be(false)
    expect(response.parsed_body.dig("data", "source_retention_summary")).to include(
      "failed_file_count" => 1,
      "ready" => false
    )

    post "/api/v1/admin/historical_imports/#{batch.id}/apply", params: {
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to match(/source file.*verified/i)
    expect(batch.reload).to be_previewed
  end

  it "does not let a source-file id escape its batch or company scope" do
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
    cleanup_quickbooks_history_uploads
    other_company = create(:company, organization: company.organization, historical_payroll_enabled: true)
    other_actor = create(:user, company: other_company, organization: company.organization, role: "admin")
    other_batch = QuickbooksHistory::ImportService.new(company: other_company, files: quickbooks_history_uploads(suffix: "other"), actor: other_actor).call.batch
    other_source_file = other_batch.historical_import_source_files.first

    get "/api/v1/admin/historical_imports/#{batch.id}/source_files/#{other_source_file.id}/download"

    expect(response).to have_http_status(:not_found)
  end

  it "returns a clear error when a selected live employee is unavailable" do
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
    worker = batch.historical_workers.find_by!(source_name: "Worker, Alice")

    patch "/api/v1/admin/historical_imports/#{batch.id}/workers/#{worker.id}", params: { employee_id: -1 }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include(
      "error" => "The selected live employee could not be found for this client",
      "details" => {}
    )
    expect(worker.reload).to have_attributes(employee_id: nil, mapping_status: "needs_review")
  end

  it "lets managers review and mutate imports for enabled clients" do
    manager = create(:user, company: company, organization: company.organization, role: "manager")
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_user).and_return(manager)

    get "/api/v1/admin/historical_imports"
    expect(response).to have_http_status(:ok)

    post "/api/v1/admin/historical_imports/preview", params: { files: quickbooks_history_uploads }
    expect(response).to have_http_status(:ok)
  end

  it "keeps the workspace unavailable until the client feature is enabled" do
    company.update!(historical_payroll_enabled: false)

    get "/api/v1/admin/historical_imports"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include(
      "error" => "Historical payroll is not enabled for this client",
      "details" => {}
    )
  end

  it "applies the feature gate before looking up a batch" do
    company.update!(historical_payroll_enabled: false)

    get "/api/v1/admin/historical_imports/999999"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Historical payroll is not enabled for this client")
  end

  it "returns structured validation details when preview persistence fails" do
    invalid_batch = HistoricalImportBatch.new
    invalid_batch.errors.add(:source_label, "can't be blank")
    persistence_error = ActiveRecord::RecordInvalid.new(invalid_batch)
    result = QuickbooksHistory::ImportService::Result.new(idempotent: false, error: persistence_error)
    allow_any_instance_of(QuickbooksHistory::ImportService).to receive(:call).and_return(result)

    post "/api/v1/admin/historical_imports/preview", params: { files: quickbooks_history_uploads }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)).to include(
      "error" => persistence_error.message,
      "details" => { "source_label" => [ "can't be blank" ] }
    )
  end

  it "returns a parser error envelope for a malformed upload bundle" do
    details = payroll_details_rows
    details[5][5] = "not money"

    post "/api/v1/admin/historical_imports/preview", params: {
      files: authoritative_quickbooks_files(details: details, history: paycheck_history_rows)
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include(
      "error" => a_string_matching(/Gross pay - total is not a valid number/),
      "details" => {}
    )
    expect(HistoricalImportBatch.count).to eq(0)
  end

  it "fails safely when no active company is selected" do
    super_admin = create(:user, company: company, organization: company.organization, role: "super_admin")
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_user).and_return(super_admin)
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_company_id).and_return(nil)
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_company).and_return(nil)

    get "/api/v1/admin/historical_imports"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Historical payroll is not enabled for this client")
  end

  it "does not expose encrypted employee setup snapshots in API responses" do
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch

    get "/api/v1/admin/historical_imports/#{batch.id}"

    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).not_to include("000-00-0001")
    expect(JSON.parse(response.body).dig("data", "workers", 0)).not_to have_key("private_snapshot")
  end

  it "scopes batch access to the active company" do
    other_company = create(:company, organization: company.organization)
    other_batch = HistoricalImportBatch.create!(
      company: other_company,
      source_label: "Other history",
      bundle_digest: "other-digest",
      importer_version: "test"
    )

    get "/api/v1/admin/historical_imports/#{other_batch.id}"

    expect(response).to have_http_status(:not_found)
  end
end
