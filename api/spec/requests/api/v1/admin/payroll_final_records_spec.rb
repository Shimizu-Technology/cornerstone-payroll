# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollFinalRecords", type: :request do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company:, organization: company.organization, role: "accountant") }
  let!(:period) { create(:pay_period, :committed, company:) }
  let!(:employee) { create(:employee, company:) }
  let!(:item) do
    create(:payroll_item, company:, pay_period: period, employee:, gross_pay: 500,
      total_deductions: 100, net_pay: 400, withholding_tax: 100, check_number: "1200")
  end
  let(:headers) { { "X-E2E-User-Email" => actor.email, "X-Company-Id" => company.id.to_s } }

  around do |example|
    original = ENV["E2E_TEST_MODE"]
    ENV["E2E_TEST_MODE"] = "true"
    example.run
  ensure
    original.nil? ? ENV.delete("E2E_TEST_MODE") : ENV["E2E_TEST_MODE"] = original
  end

  before { PayrollLiabilityPostingService.post!(pay_period: period) }

  it "returns the company-scoped final record without allowing browser caching" do
    get "/api/v1/admin/pay_periods/#{period.id}/final_record", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch("Cache-Control")).to include("no-store")
    expect(response.parsed_body.dig("final_record", "journal", "balanced")).to be(true)
    expect(response.parsed_body.dig("final_record", "official_payroll", "net_pay")).to eq("400.0")
  end

  it "exports an accountant-ready workbook and PDF" do
    get "/api/v1/admin/pay_periods/#{period.id}/final_record.xlsx", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq(SpreadsheetReportExporter::CONTENT_TYPE)
    expect(response.headers.fetch("Cache-Control")).to include("no-store")

    get "/api/v1/admin/pay_periods/#{period.id}/final_record.pdf", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.body).to start_with("%PDF")
  end

  it "does not expose another company's record" do
    foreign_company = create(:company)
    foreign_period = create(:pay_period, :committed, company: foreign_company)

    get "/api/v1/admin/pay_periods/#{foreign_period.id}/final_record", headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it "rejects client users" do
    client = create(:user, company:, organization: company.organization, role: "client")
    get "/api/v1/admin/pay_periods/#{period.id}/final_record",
      headers: headers.merge("X-E2E-User-Email" => client.email)

    expect(response).to have_http_status(:forbidden)
  end
end
