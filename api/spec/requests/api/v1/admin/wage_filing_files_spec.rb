# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Wage filing files", type: :request do
  let(:company) { create(:company, ein: "66-1234567", filing_contact_name: "Contact", phone: "6715554321", email: "employer@example.com") }
  let(:user) { create(:user, company: company, role: "admin") }
  let(:employee) { create(:employee, company: company, ssn_encrypted: "123-45-6789") }
  let(:row) { Efw2W2GuGenerator::BOXES.index_with { 100 }.merge(employee_id: employee.id, box5_medicare_wages_tips: 200, box12: [ { code: "D", amount: 100 }, { code: "AA", amount: 50 } ]) }
  let(:report) { { meta: { year: 2026 }, employees: [ row ], totals: row.slice(*Efw2W2GuGenerator::BOXES).merge(box12_code_d_total: 100, box12_code_aa_total: 50) } }
  before do
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(user)
    allow_any_instance_of(W2GuAggregator).to receive(:generate).and_return(report)
    create(:payroll_filing_responsibility, company: company, tax_year: 2026, quarter: nil, filing_type: "w2_gu", responsible_party: "cornerstone")
    FilingSubmitter.create!(organization: company.organization, ein: "66-7654321", name: "Practice", address_line1: "1 Main", city: "Hagatna", state: "GU", zip: "96910", contact_name: "Dafne", contact_phone: "6715551234", contact_email: "filing@example.com", bso_user_id: "ABCDEFGH")
  end

  it "refuses draft and final without a recorded Cornerstone decision" do
    company.payroll_filing_responsibilities.destroy_all
    %w[draft final].each do |mode|
      get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: mode }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Record that Cornerstone files")
    end
  end

  it "denies accountants without client management EFW2 but allows the W-3SS PDF" do
    user.update!(role: "accountant")
    %w[draft final].each do |mode|
      get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: mode }
      expect(response).to have_http_status(:forbidden)
    end
    get "/api/v1/admin/reports/w3ss_pdf", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
  end

  it "refuses the e-file and W-3SS in a test workspace, which carries copied live identities" do
    source = create(:company, organization: company.organization)
    company.update_columns(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
      migration_source_company_id: source.id, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)

    expect(AuditLog).not_to receive(:record!)
    [ [ "w2_gu_efw2", "draft" ], [ "w2_gu_efw2", "final" ], [ "w3ss_pdf", "draft" ] ].each do |action, mode|
      get "/api/v1/admin/reports/#{action}", params: { year: 2026, mode: mode }
      expect(response).to have_http_status(:forbidden), "#{action} #{mode}: #{response.body}"
      expect(response.parsed_body["code"]).to eq(Company::CONTAINED_COMPANY_RESTRICTED_CODE)
      expect(response.parsed_body["error"]).to include("practice company (test workspace)", "turned off")
      expect(response.body).not_to include("123456789")
    end
  end

  it "allows accountants delegated client management for this client" do
    user.update!(role: "accountant")
    grantor = create(:user, company: company, role: "admin")
    create(:company_assignment, user: user, company: company, client_management: true, granted_by: grantor)
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
  end

  it "rechecks delegated EFW2 access after waiting for the company lock" do
    user.update!(role: "accountant")
    grantor = create(:user, company: company, role: "admin")
    assignment = create(:company_assignment, user: user, company: company, client_management: true, granted_by: grantor)
    allow_any_instance_of(Company).to receive(:lock!).and_wrap_original do |original, *args|
      assignment.update!(client_management: false)
      original.call(*args)
    end
    expect(W2GuAggregator).not_to receive(:new)
    expect(AuditLog).not_to receive(:record!)
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("123456789", "RW")
  end

  it "audits a draft download without SSNs and prevents caching" do
    expect { get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" } }.to change(AuditLog.where(action: "efw2#download"), :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Content-Disposition"]).to include("DRAFT")
    log = AuditLog.find_by!(action: "efw2#download")
    expect(log.user_id).to eq(user.id)
    expect(log.metadata).to include("file_digest" => FilingFileDigest.call(response.body), "digest_alg" => "hmac-sha256-v1")
    expect(log.metadata).not_to have_key("sha256")
    expect(log.metadata.to_json).not_to include(Digest::SHA256.hexdigest(response.body))
    expect(FilingFileDigest.matches?(response.body, log)).to be(true)
    expect(log.metadata.to_json).not_to include("123456789")
  end

  it "keeps the SSN out of reach of someone who rebuilds the file from the audit row" do
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
    log = AuditLog.find_by!(action: "efw2#download")
    # The file is deterministic: anyone with the visible data could rebuild it.
    rebuilt = Efw2W2GuGenerator.new(company: company, year: 2026, submitter: FilingSubmitter.find_by!(organization_id: company.organization_id), report: report).generate
    expect(rebuilt).to eq(response.body)
    # An offline guess hashed without the server key matches nothing in the row.
    expect(log.metadata.values.map(&:to_s)).not_to include(Digest::SHA256.hexdigest(rebuilt))
    guess = rebuilt.sub("123456789", "123456788")
    expect(guess).not_to eq(rebuilt)
    expect(log.metadata.values.map(&:to_s)).not_to include(Digest::SHA256.hexdigest(guess))
    # Only the server, holding the key, can tie the bytes to the download.
    expect(FilingFileDigest.matches?(rebuilt, log)).to be(true)
    expect(FilingFileDigest.matches?(guess, log)).to be(false)
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
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "returns a records-only W-3SS with the same totals" do
    get "/api/v1/admin/reports/w3ss_pdf", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
    reader = PDF::Reader.new(StringIO.new(response.body))
    expect(reader.pages.length).to eq(1)
    expect(reader.pages.first.text).to include("For your records", "2026", "100.00", "150.00")
    metadata = AuditLog.find_by!(action: "w3ss#download").metadata
    expect(metadata).to include("file_digest" => FilingFileDigest.call(response.body), "digest_alg" => "hmac-sha256-v1")
    expect(metadata).not_to have_key("sha256")
  end

  it "uses the reports authorization for client users" do
    user.update!(role: "client")
    get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:forbidden)
  end
end
