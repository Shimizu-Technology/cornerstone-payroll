# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Wage filing files", type: :request do
  let(:company) { create(:company, ein: "66-1234567", filing_contact_name: "Contact", phone: "6715554321", email: "employer@example.com") }
  let(:user) { create(:user, company: company, role: "admin") }
  let(:employee) { create(:employee, company: company, ssn_encrypted: "123-45-6789") }
  let(:row) { Efw2W2GuGenerator::BOXES.index_with { 100 }.merge(employee_id: employee.id, box12: [ { code: "D", amount: 100 }, { code: "AA", amount: 50 } ]) }
  let(:report) { { meta: { year: 2026 }, employees: [ row ], totals: row.slice(*Efw2W2GuGenerator::BOXES).merge(box12_code_d_total: 100, box12_code_aa_total: 50) } }
  before do
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(user)
    allow_any_instance_of(W2GuAggregator).to receive(:generate).and_return(report)
    FilingSubmitter.create!(organization: company.organization, ein: "66-7654321", name: "Practice", address_line1: "1 Main", city: "Hagatna", state: "GU", zip: "96910", contact_name: "Dafne", contact_phone: "6715551234", contact_email: "filing@example.com", bso_user_id: "ABCDEFGH")
  end

  it "audits a draft download without SSNs and prevents caching" do
    expect { get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" } }.to change(AuditLog.where(action: "efw2#download"), :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Content-Disposition"]).to include("DRAFT")
    log = AuditLog.find_by!(action: "efw2#download")
    expect(log.user_id).to eq(user.id)
    expect(log.metadata["sha256"]).to eq(Digest::SHA256.hexdigest(response.body))
    expect(log.metadata.to_json).not_to include("123456789")
  end

  it "requires a current readiness fingerprint for final files" do
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "final" }
    expect(response).to have_http_status(:unprocessable_entity)
    filing = W2FilingReadiness.create!(company: company, year: 2026, status: "filing_ready", ready_fingerprint: W2FilingInputsFingerprint.new(company: company, year: 2026, report: report).call)
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "final" }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Disposition"]).to include("FINAL")
    company.update!(employment_code: "F")
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "final" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(filing.reload.status).to eq("filing_ready")
  end

  it "honors filing responsibility blockers" do
    allow(PayrollFilingResponsibilityGate).to receive(:annual).and_return({ filings: { "w2_gu" => { blockers: [ "Prior provider files these wages" ], capabilities: { can_export_filing_ready: false, can_export_draft: true } } } })
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "final" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("Prior provider")
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
  end

  it "returns a records-only W-3SS with the same totals" do
    get "/api/v1/admin/reports/w3ss_pdf", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
    reader = PDF::Reader.new(StringIO.new(response.body))
    expect(reader.pages.length).to eq(1)
    expect(reader.pages.first.text).to include("For your records", "2026", "100.00", "150.00")
    expect(AuditLog.find_by!(action: "w3ss#download").metadata["sha256"]).to eq(Digest::SHA256.hexdigest(response.body))
  end

  it "uses the reports authorization for client users" do
    user.update!(role: "client")
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:forbidden)
  end
end
