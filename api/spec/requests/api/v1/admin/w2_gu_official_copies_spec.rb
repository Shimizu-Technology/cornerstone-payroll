# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "W-2GU official copies", type: :request do
  let!(:company) { create(:company, name: "Tumon Bakery", ein: "98-7654321") }
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department, last_name: "Santos", ssn_encrypted: "123-45-6789") }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:threshold_2026) { create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000) }
  let(:acting_user) { admin }

  before do
    [ Api::V1::Admin::ReportsController, Api::V1::Admin::PayrollFilingResponsibilitiesController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user) { acting_user }
      allow_any_instance_of(controller).to receive(:current_company_id) { company.id }
    end
    pay(Date.new(2026, 3, 6))
  end

  def pay(pay_date)
    period = create(:pay_period, :committed, company: company, start_date: pay_date - 17.days, end_date: pay_date - 3.days, pay_date: pay_date)
    create(:payroll_item, company: company, employee: employee, pay_period: period,
      gross_pay: 2_000, net_pay: 1_600, withholding_tax: 150,
      social_security_tax: 124, employer_social_security_tax: 124,
      medicare_tax: 29, employer_medicare_tax: 29,
      social_security_taxable_wages: 2_000, social_security_taxable_tips: 0, medicare_taxable_wages: 2_000,
      fit_taxable_wages: 2_000)
  end

  def decide(w2_party)
    { "w2_gu" => w2_party, "form_1099" => "no_filing" }.each do |filing_type, party|
      put "/api/v1/admin/payroll_filing_responsibilities", params: {
        responsibility: { tax_year: 2026, filing_types: [ filing_type ], responsible_party: party, imported_payroll_inclusion: "included" }
      }
      expect(response).to have_http_status(:ok), response.body
    end
  end

  def mark_ready
    post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2026 }
    post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2026, notes: "Year-end review" }
    expect(response).to have_http_status(:ok), response.body
  end

  def download(copy, year: 2026)
    get "/api/v1/admin/reports/w2_gu_official_copies", params: { year: year, copy: copy }
  end

  def pdf_text
    PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
  end

  def copy_logs
    AuditLog.where(action: "reports#w2_gu_official_copies").order(:id)
  end

  context "when Cornerstone files the W-2s" do
    before { decide("cornerstone") }

    it "sends a watermarked draft before the W-2s are marked ready, without caching" do
      download("employee")

      expect(response).to have_http_status(:ok), response.body
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.headers["Content-Disposition"]).to include("W-2GU_2026_Tumon_Bakery_Employee_Copies_B_C_DRAFT.pdf")
      expect(pdf_text).to include("DRAFT — the 2026 W-2s are not marked ready", "XXX-XX-6789")
      expect(pdf_text).not_to include("123-45-6789")
      expect(copy_logs.last.metadata).to include("document_kind" => "w2_gu_employee_copies_b_c", "status" => "draft", "contains_full_ssn" => false)
    end

    it "sends final copies only while the ready mark matches the inputs" do
      mark_ready

      download("drt")
      expect(response).to have_http_status(:ok), response.body
      expect(response.headers["Content-Disposition"]).to include("W-2GU_2026_Tumon_Bakery_Copy1_DRT.pdf")
      expect(pdf_text).to include("123-45-6789", "Copy 1—For Guam Department of Revenue and Taxation")
      expect(pdf_text).not_to include("DRAFT")

      pay(Date.new(2026, 4, 3))
      download("drt")
      expect(response).to have_http_status(:ok), response.body
      expect(pdf_text).to include("DRAFT — the 2026 W-2s are not marked ready")
      expect(copy_logs.map { |log| log.metadata["status"] }).to eq(%w[final draft])
    end

    it "audits every full-SSN download with the actor, client, year, document and sign-off, and no SSN" do
      mark_ready
      readiness = W2FilingReadiness.find_by!(company: company, year: 2026)

      expect { download("drt") }.to change(copy_logs, :count).by(1)

      expect(response.headers["Cache-Control"]).to include("no-store")
      log = copy_logs.last
      expect(log).to have_attributes(user_id: admin.id, company_id: company.id, event_category: "document_access", record_type: "reports")
      expect(log.metadata).to include(
        "tax_year" => 2026, "document_kind" => "w2_gu_copy_1_drt", "contains_full_ssn" => true, "status" => "final",
        "inputs_fingerprint" => readiness.ready_fingerprint, "ready_fingerprint" => readiness.ready_fingerprint,
        "readiness_status" => "filing_ready", "employee_count" => 1
      )
      expect(log.to_json).not_to include("6789")
      # The request's own generic audit entry is not written as well.
      expect(AuditLog.where(action: "reports#w2_gu_official_copies").count).to eq(1)
    end

    it "sends nothing when the download can't be recorded" do
      allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit unavailable")

      download("drt")

      expect(response).to have_http_status(:service_unavailable)
      expect(response.media_type).to eq("application/json")
      expect(response.body).not_to include("123-45-6789")
      expect(response.parsed_body["error"]).to include("not sent")
    end

    it "rejects an unknown copy and a year without the IRS template" do
      download("copy_a")
      expect(response).to have_http_status(:unprocessable_content)

      download("drt", year: 2025)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("2026 only")
      expect(copy_logs).to be_empty
    end

    it "uses the W-2GU report's access: staff with access to the client" do
      outsider_company = create(:company)
      outsider = create(:user, company: outsider_company, organization: outsider_company.organization, role: "admin")
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(outsider)

      download("drt")
      expect(response).to have_http_status(:forbidden)

      portal_user = create(:user, company: company, organization: company.organization, role: "client")
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(portal_user)
      download("drt")
      expect(response).to have_http_status(:forbidden)
      expect(copy_logs).to be_empty
    end
  end

  it "offers no copies when the client files its own W-2s" do
    decide("client")

    download("employee")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("Cornerstone does not file 2026 W-2s")
    expect(copy_logs).to be_empty
  end

  it "offers no copies before anyone has decided who files" do
    download("drt")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.headers["Cache-Control"]).to include("no-store")
  end
end
