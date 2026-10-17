# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Official quarterly template tax years", type: :request do
  let!(:company) { create(:company) }
  let!(:user) { create(:user, :admin, company: company) }

  before do
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(user)
  end

  {
    form_941_gu_pdf: :get,
    quarterly_compliance_packet_pdf: :get,
    quarterly_compliance_packet_form_941_pdf: :get,
    quarterly_compliance_packet_official_form_defaults: :get,
    quarterly_compliance_packet_official_form_preview: :post,
    quarterly_compliance_packet_official_form_download: :post
  }.each do |endpoint, method|
    [ 2025, 2027 ].each do |year|
      it "rejects #{year} through #{endpoint} without emitting or recording a filing" do
        expect {
          public_send(method, "/api/v1/admin/reports/#{endpoint}", params: {
            year: year, quarter: 2, form_type: "form_941",
            fields: { year: 2026, meta: { year: 2026 } }
          })
        }.not_to change { [ QuarterlyCompliancePacket.count, PayrollFilingRecord.count, PayrollFilingEvent.count, PayrollItem.count ] }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.content_type).to include("application/json")
        expect(response.headers["Content-Disposition"]).to be_nil
        expect(response.parsed_body.fetch("error")).to include("only for tax year 2026", "For #{year}", "worksheet", "matching IRS Form 941 revision")
      end
    end
  end

  %w[preview download].each do |action|
    it "rejects a fractional JSON year through edited #{action} before integer coercion" do
      post "/api/v1/admin/reports/quarterly_compliance_packet_official_form_#{action}",
        params: { year: 2026.9, quarter: 2, form_type: "form_941" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.headers["Content-Disposition"]).to be_nil
      expect(response.parsed_body.dig("official_form_template", "available")).to be(false)
      expect(response.parsed_body.fetch("error")).to include("For 2026.9", "matching IRS Form 941 revision")
    end
  end

  it "discloses the same authoritative template availability while retaining historical JSON and Excel" do
    %w[form_941_gu quarterly_compliance_packet].each do |endpoint|
      [ 2025, 2026 ].each do |year|
        get "/api/v1/admin/reports/#{endpoint}", params: { year: year, quarter: 2 }
        expect(response).to have_http_status(:ok)
        report = response.parsed_body.fetch("report")
        expect(report.dig("meta", "year")).to eq(year)
        expect(report.fetch("official_form_template")).to eq(
          QuarterlyComplianceOfficialForms::Form941.template_status(year).stringify_keys
        )
      end
      get "/api/v1/admin/reports/#{endpoint}_xlsx", params: { year: 2025, quarter: 2 }
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("2025_q2.xlsx")
    end
  end

  %w[schedule_b w1 swica].each do |form_type|
    it "retains #{form_type} defaults and prior-year dynamic PDF output" do
      get "/api/v1/admin/reports/quarterly_compliance_packet_official_form_defaults",
        params: { year: 2025, quarter: 2, form_type: form_type }
      expect(response).to have_http_status(:ok)

      get "/api/v1/admin/reports/quarterly_compliance_packet_#{form_type}_pdf", params: { year: 2025, quarter: 2 }
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("2025_q2.pdf")
      expect(PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join.gsub(/\s+/, "")).to include("2025")
    end
  end

  it "keeps the supported 2026 standalone and whole-packet exports available" do
    %w[form_941_gu_pdf quarterly_compliance_packet_pdf].each do |endpoint|
      get "/api/v1/admin/reports/#{endpoint}", params: { year: 2026, quarter: 2 }
      expect(response).to have_http_status(:ok)
      expect(response.body).to start_with("%PDF")
      expect(PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join).to include("2026", "DRAFT")
    end
  end
end
