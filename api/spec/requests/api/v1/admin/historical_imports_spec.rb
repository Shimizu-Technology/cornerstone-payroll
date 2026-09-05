# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::HistoricalImports", type: :request do
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }

  before do
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_company_id).and_return(company.id)
  end

  after { cleanup_quickbooks_history_uploads }

  it "previews, paginates, applies, and locks a reconciled QuickBooks bundle" do
    post "/api/v1/admin/historical_imports/preview", params: { files: quickbooks_history_uploads }

    expect(response).to have_http_status(:ok)
    batch_id = response.parsed_body.dig("data", "id")
    expect(response.parsed_body.dig("data", "preview_summary")).to include(
      "paycheck_count" => 2,
      "period_count" => 2
    )
    expect(PayPeriod.count).to eq(0)
    expect(PayrollItem.count).to eq(0)

    get "/api/v1/admin/historical_imports/#{batch_id}", params: { per_page: 1, search: "Alice" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "paychecks").sole).to include(
      "source_employee_name" => "Worker, Alice",
      "gross_pay" => "1000.0",
      "net_pay" => "725.0"
    )
    expect(response.parsed_body.dig("meta", "total_count")).to eq(1)

    post "/api/v1/admin/historical_imports/#{batch_id}/apply", params: {
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "status")).to eq("applied")

    post "/api/v1/admin/historical_imports/#{batch_id}/lock"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "status")).to eq("locked")

    get "/api/v1/admin/historical_imports"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("archive")).to include(
      "applied_batch_count" => 1,
      "paycheck_count" => 2,
      "gross_pay" => "3000.0",
      "net_pay" => "2325.0"
    )
  end

  it "lets accountants review history but not mutate imports" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::HistoricalImportsController).to receive(:current_user).and_return(accountant)

    get "/api/v1/admin/historical_imports"
    expect(response).to have_http_status(:ok)

    post "/api/v1/admin/historical_imports/preview", params: { files: quickbooks_history_uploads }
    expect(response).to have_http_status(:forbidden)
    expect(HistoricalImportBatch.count).to eq(0)
  end

  it "does not expose encrypted employee setup snapshots in API responses" do
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch

    get "/api/v1/admin/historical_imports/#{batch.id}"

    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).not_to include("000-00-0001")
    expect(response.parsed_body.dig("data", "workers", 0)).not_to have_key("private_snapshot")
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
