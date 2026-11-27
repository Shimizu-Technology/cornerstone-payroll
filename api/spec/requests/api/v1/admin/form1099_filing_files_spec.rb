# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "1099 filing files", type: :request do
  let(:company) { create(:company, ein: "66-1234567", filing_contact_name: "Contact", phone: "6715554321", email: "employer@example.com") }
  let(:user) { create(:user, company: company, role: "admin") }
  let(:employee) { create(:employee, :contractor, company: company, ssn_encrypted: "123-45-6789") }
  let(:row) { { employee_id: employee.id, name: employee.full_name, tin_type: "SSN", total_compensation: 3000, federal_withheld: 25 } }
  let(:report) { { reportable_contractors: [ row ], totals: { reportable_federal_withheld: 25, reportable_compensation: 3000 } } }
  before do
    create(:information_return_threshold, form_type: "1099_nec", tax_year: 2026, threshold_amount: 2000)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(user)
    allow_any_instance_of(Form1099NecAggregator).to receive(:generate).and_return(report)
    create(:payroll_filing_responsibility, company: company, tax_year: 2026, quarter: nil, filing_type: "form_1099", responsible_party: "cornerstone")
    FilingSubmitter.create!(organization: company.organization, ein: "66-7654321", name: "Practice", address_line1: "1 Main", city: "Hagatna", state: "GU", zip: "96910", contact_name: "Dafne", contact_phone: "6715551234", contact_email: "filing@example.com", bso_user_id: "ABCDEFGH", tcc: "ABCDE")
  end

  it "refuses draft and final without a recorded Cornerstone decision" do
    company.payroll_filing_responsibilities.destroy_all
    %w[draft final].each do |mode|
      get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: mode }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Record that Cornerstone files")
    end
  end

  it "denies accountants without client management Pub 1220 and the 1096 PDF" do
    user.update!(role: "accountant")
    %w[draft final].each do |mode|
      get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: mode }
      expect(response).to have_http_status(:forbidden)
    end
    get "/api/v1/admin/reports/form_1096_totals", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:forbidden)
  end

  it "refuses the e-file and 1096 in a test workspace, which carries copied live identities" do
    source = create(:company, organization: company.organization)
    company.update_columns(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
      migration_source_company_id: source.id, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)

    expect(AuditLog).not_to receive(:record!)
    [ [ "form_1099_pub1220", "draft" ], [ "form_1099_pub1220", "final" ], [ "form_1096_totals", "draft" ] ].each do |action, mode|
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
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
  end

  it "rechecks delegated Pub 1220 access after waiting for the company lock" do
    user.update!(role: "accountant")
    grantor = create(:user, company: company, role: "admin")
    assignment = create(:company_assignment, user: user, company: company, client_management: true, granted_by: grantor)
    allow_any_instance_of(Company).to receive(:lock!).and_wrap_original do |original, *args|
      assignment.update!(client_management: false)
      original.call(*args)
    end
    expect(Form1099NecAggregator).not_to receive(:new)
    expect(AuditLog).not_to receive(:record!)
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("123456789", "RW")
  end

  it "audits a draft download without SSNs and prevents caching" do
    expect { get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" } }.to change(AuditLog.where(action: "pub1220#download"), :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Content-Disposition"]).to include("DRAFT")
    log = AuditLog.find_by!(action: "pub1220#download")
    expect(log.user_id).to eq(user.id)
    expect(log.metadata).to include("file_digest" => FilingFileDigest.call(response.body), "digest_alg" => "hmac-sha256-v1")
    expect(log.metadata).not_to have_key("sha256")
    expect(log.metadata.to_json).not_to include(Digest::SHA256.hexdigest(response.body))
    expect(FilingFileDigest.matches?(response.body, log)).to be(true)
    expect(log.metadata.to_json).not_to include("123456789")
  end

  it "keeps the TIN out of reach of someone who rebuilds the file from the audit row" do
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
    log = AuditLog.find_by!(action: "pub1220#download")
    rebuilt = Form1099Pub1220Generator.new(company: company, year: 2026, submitter: FilingSubmitter.find_by!(organization_id: company.organization_id), draft: true).generate
    expect(rebuilt).to eq(response.body)
    expect(log.metadata.values.map(&:to_s)).not_to include(Digest::SHA256.hexdigest(rebuilt))
    guess = rebuilt.sub("123456789", "123456788")
    expect(guess).not_to eq(rebuilt)
    expect(log.metadata.values.map(&:to_s)).not_to include(Digest::SHA256.hexdigest(guess))
    expect(FilingFileDigest.matches?(rebuilt, log)).to be(true)
    expect(FilingFileDigest.matches?(guess, log)).to be(false)
  end

  it "refuses a final until the 1099s are marked ready, and emits a non-test final when they are" do
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "final" }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("Mark the 1099s ready first")
    allow(Form1099Readiness).to receive(:final?).and_return(true)
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "final" }
    expect(response).to have_http_status(:ok)
    expect(response.body[27]).to eq(" ")
  end

  it "refuses files when inputs change during generation" do
    calls = 0
    allow_any_instance_of(Form1099Pub1220Generator).to receive(:generate).and_wrap_original do |original|
      calls += 1
      file = original.call
      calls == 1 ? file : file.sub("PRACTICE", "CHANGED ")
    end
    expect(AuditLog).not_to receive(:record!)
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("inputs changed")
  end

  it "rechecks delegated access after generation" do
    user.update!(role: "accountant")
    grantor = create(:user, company: company, role: "admin")
    assignment = create(:company_assignment, user: user, company: company, client_management: true, granted_by: grantor)
    allow_any_instance_of(Form1099Pub1220Generator).to receive(:generate).and_wrap_original do |original|
      file = original.call
      assignment.update!(client_management: false)
      file
    end
    expect(AuditLog).not_to receive(:record!)
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:forbidden)
  end

  it "honors responsibility gate blockers" do
    allow_any_instance_of(PayrollFilingResponsibilityGate).to receive(:payload).and_return({ blockers: [ "Prior provider files these payments" ] })
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("Prior provider")
  end

  it "refuses a file when a gate blocker appears during generation" do
    calls = 0
    allow_any_instance_of(PayrollFilingResponsibilityGate).to receive(:payload).and_wrap_original do |original|
      calls += 1
      calls == 1 ? original.call : { blockers: [ "A history batch was locked after the decision" ] }
    end
    expect(AuditLog).not_to receive(:record!)
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("blockers changed during generation")
  end

  it "refuses a final without a TCC even when readiness passes" do
    allow(Form1099Readiness).to receive(:final?).and_return(true)
    FilingSubmitter.find_by!(organization: company.organization).update!(tcc: nil)
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "final" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["problems"]).to include(Form1099Pub1220Generator::TCC_PROBLEM)
  end

  it "returns a records-only 1096 with the same totals" do
    get "/api/v1/admin/reports/form_1096_totals", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
    reader = PDF::Reader.new(StringIO.new(response.body))
    expect(reader.pages.length).to eq(1)
    expect(reader.pages.first.text).to include("For your records", "2026", "3,000.00", "25.00")
    metadata = AuditLog.find_by!(action: "form1096#download").metadata
    expect(metadata).to include("file_digest" => FilingFileDigest.call(response.body), "digest_alg" => "hmac-sha256-v1")
    expect(metadata).not_to have_key("sha256")
  end

  it "uses the reports authorization for client users" do
    user.update!(role: "client")
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:forbidden)
  end
  it "exports real payroll TIN/name fields and blocks a real unidentified check" do
    allow_any_instance_of(Form1099NecAggregator).to receive(:generate).and_call_original
    change_compensation!(employee, employment_type: "contractor", contractor_type: "business", contractor_ein: "66-2345678", business_name: "ABC Services")
    period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 5, 15))
    create(:payroll_item, company: company, employee: employee, pay_period: period,
      employment_type: "contractor", gross_pay: 1500, net_pay: 1400, withholding_tax: 100)
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
    expect(response.body[1510, 10]).to eq("1662345678")
    expect(response.body[1787, 40].strip).to eq("ABC SERVICES")
    check = create(:non_employee_check, company: company, check_type: "contractor", payable_to: "Unidentified Vendor",
      payment_date: Date.new(2026, 5, 15), amount: 2100, printed_at: Time.current)
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Unidentified Vendor: missing TIN and address")
    check.update!(voided: true, voided_at: Time.current, void_reason: "Duplicate check, identity reconciled with payroll")
    get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
    expect(response).to have_http_status(:ok)
  end
end
