# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::HistoricalReports", type: :request do
  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }

  before do
    allow_any_instance_of(Api::V1::Admin::HistoricalReportsController).to receive(:current_user).and_return(accountant)
    allow_any_instance_of(Api::V1::Admin::HistoricalReportsController).to receive(:current_company_id).and_return(company.id)
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  after do
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  it "lets an accountant browse paginated accepted history with provenance but no private employee data" do
    batch = accepted_batch

    get "/api/v1/admin/historical_reports/register", params: { page: 1, per_page: 1, year: 2024 }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig("meta", "total_count")).to eq(2)
    expect(body.dig("meta", "total_pages")).to eq(2)
    expect(body.dig("report", "rows").size).to eq(1)
    expect(body.dig("report", "summary")).to include(
      "detailed_paycheck_count" => 1,
      "opening_summary_count" => 1
    )
    expect(body.dig("report", "provenance").sole.fetch("batch_id")).to eq(batch.id)
    expect(body.to_json).not_to include("000-00-0001", "private_snapshot", "storage_key")
  end

  it "exports CSV, XLSX, and PDF from the same historical report contract and audits each download" do
    accepted_batch

    get "/api/v1/admin/historical_reports/deductions/csv", params: { year: 2024 }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.body).to include("Category,Component,Amount", "401(k) Pre-Tax", "Loan")

    get "/api/v1/admin/historical_reports/deductions/xlsx", params: { year: 2024 }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq(SpreadsheetReportExporter::CONTENT_TYPE)
    expect(response.body.byteslice(0, 2)).to eq("PK")

    get "/api/v1/admin/historical_reports/deductions/pdf", params: { year: 2024 }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.body.byteslice(0, 4)).to eq("%PDF")

    expect(AuditLog.where(action: "historical_reports#export").count).to eq(3)
    expect(AuditLog.where(action: "historical_reports#export").pluck(:user_id).uniq).to eq([ accountant.id ])
  end

  it "keeps previews and other companies out of official historical reports" do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call
    other_company = create(:company, historical_payroll_enabled: true)
    other_actor = create(:user, company: other_company, organization: other_company.organization, role: "admin")
    cleanup_quickbooks_history_uploads
    other_batch = QuickbooksHistory::ImportService.new(
      company: other_company,
      files: quickbooks_history_uploads(suffix: "other"),
      actor: other_actor
    ).call.batch
    review_historical_workers_as_archive_only(other_batch, actor: other_actor)
    QuickbooksHistory::LifecycleService.new(batch: other_batch, actor: other_actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )

    get "/api/v1/admin/historical_reports/register"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("report", "rows")).to eq([])
    expect(response.parsed_body.dig("report", "provenance")).to eq([])
  end

  it "requires the company feature and validates report filters" do
    company.update!(historical_payroll_enabled: false)
    get "/api/v1/admin/historical_reports/register"
    expect(response).to have_http_status(:forbidden)

    company.update!(historical_payroll_enabled: true)
    get "/api/v1/admin/historical_reports/not-real"
    expect(response).to have_http_status(:unprocessable_entity)
    get "/api/v1/admin/historical_reports/register", params: { year: "invalid" }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  private

  def accepted_batch
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
    review_historical_workers_as_archive_only(batch, actor: admin)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    batch
  end
end
