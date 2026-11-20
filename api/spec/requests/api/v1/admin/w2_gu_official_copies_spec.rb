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
    get "/api/v1/admin/reports/#{copy == 'drt' ? 'w2_gu_copy_1_drt' : 'w2_gu_employee_copies'}", params: { year: year }
  end

  def pdf_pages
    PDF::Reader.new(StringIO.new(response.body)).pages
  end

  # Text by glyph position; see PdfBoxText for why not Page#text.
  def pdf_text
    pdf_pages.flat_map { |page| pdf_rows(page) }.join("\n")
  end

  def copy_logs
    AuditLog.where(action: %w[reports#w2_gu_employee_copies reports#w2_gu_copy_1_drt]).order(:id)
  end

  context "when Cornerstone files the W-2s" do
    before { decide("cornerstone") }

    it "sends a watermarked draft before the W-2s are marked ready, without caching" do
      download("employee")

      expect(response).to have_http_status(:ok), response.body
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.headers["Content-Disposition"]).to include("W-2GU_2026_Tumon_Bakery_Employee_Copies_B_C_DRAFT.pdf")
      expect(pdf_text).to include("DRAFT — the 2026 W-2s are not marked ready")
      # Copy B on top and Copy C below both show only the last four digits.
      copy_b_ssn = W2GuOfficialCopies::FIELDS[:ssn]
      expect(text_in_box(pdf_pages.first, copy_b_ssn)).to eq("XXX-XX-6789")
      expect(text_in_box(pdf_pages.first, shift_rect(copy_b_ssn, W2GuOfficialCopies::HALF_PAGE))).to eq("XXX-XX-6789")
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
      expect(AuditLog.where(action: "reports#w2_gu_copy_1_drt").count).to eq(1)
    end

    it "sends nothing when the download can't be recorded" do
      allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit unavailable")

      download("drt")

      expect(response).to have_http_status(:service_unavailable)
      expect(response.media_type).to eq("application/json")
      expect(response.body).not_to include("123-45-6789")
      expect(response.parsed_body["error"]).to include("not sent")
    end

    it "rejects a year without the IRS template" do
      download("drt", year: 2025)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("2026 only")
      expect(copy_logs).to be_empty
    end

    it "sends nothing when the client's W-2 data changes while the file is made" do
      mark_ready
      allow_any_instance_of(W2GuOfficialCopies).to receive(:generate).and_wrap_original do |original, *args|
        pdf = original.call(*args)
        # Another tab saves a new address after the copies were drawn.
        employee.update!(address_line1: "200 New Street")
        pdf
      end

      download("drt")

      expect(response).to have_http_status(:conflict)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body["error"]).to eq("This client's W-2 data changed while the file was being made. Download again.")
      expect(response.body).not_to include("123-45-6789")
      expect(copy_logs).to be_empty
    end

    it "sends nothing when the sign-off is withdrawn while the file is made" do
      mark_ready
      allow_any_instance_of(W2GuOfficialCopies).to receive(:generate).and_wrap_original do |original, *args|
        pdf = original.call(*args)
        W2FilingReadiness.find_by!(company: company, year: 2026).update_columns(ready_fingerprint: nil, status: "draft")
        pdf
      end

      download("employee")

      expect(response).to have_http_status(:conflict)
      expect(copy_logs.where("metadata->>'status' = 'final'")).to be_empty
    end

    it "sends nothing when the sign-off is withdrawn while the recheck itself runs" do
      mark_ready
      calls = 0
      allow_any_instance_of(W2FilingInputsFingerprint).to receive(:call).and_wrap_original do |original, *args|
        calls += 1
        # The second fingerprint is the recheck's, after the file was drawn.
        W2FilingReadiness.find_by!(company: company, year: 2026).update!(status: "draft", ready_fingerprint: nil) if calls == 2
        original.call(*args)
      end

      download("drt")

      expect(calls).to eq(2)
      expect(response).to have_http_status(:conflict)
      expect(response.body).not_to include("123-45-6789")
      expect(copy_logs).to be_empty
    end

    it "rechecks the sign-off and writes the audit entry under the company lock that mark-ready and preflight take" do
      mark_ready
      depths = { fingerprint: [], audit: [] }
      company_locks = []
      allow_any_instance_of(W2FilingInputsFingerprint).to receive(:call).and_wrap_original do |original, *args|
        depths[:fingerprint] << ActiveRecord::Base.connection.open_transactions
        original.call(*args)
      end
      allow(AuditLog).to receive(:record!).and_wrap_original do |original, **kwargs|
        depths[:audit] << ActiveRecord::Base.connection.open_transactions
        original.call(**kwargs)
      end
      lock_sql = lambda do |*, payload|
        company_locks << payload[:sql] if payload[:sql].match?(/FROM "companies".*FOR UPDATE/m)
      end

      ActiveSupport::Notifications.subscribed(lock_sql, "sql.active_record") { download("drt") }

      expect(response).to have_http_status(:ok), response.body
      # One lock for the snapshot, a second for the recheck and the audit entry.
      expect(company_locks.length).to eq(2)
      first_lock_depth, recheck_depth = depths[:fingerprint]
      expect(recheck_depth).to eq(first_lock_depth)
      # The audit write runs in a savepoint inside that lock.
      expect(depths[:audit]).to eq([ first_lock_depth + 1 ])
      expect(copy_logs.count).to eq(1)
    end

    it "refuses copies whose names or addresses can't print whole, naming each employee and box" do
      employee.update!(first_name: "Maria", address_line1: "Lot 1234 Unit 5678 " * 40)

      download("employee")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["problems"]).to eq([ "Maria Santos: the address is too long to fit Box f — shorten it on the employee's profile." ])
      expect(response.parsed_body["error"]).to include("Maria Santos: the address is too long")
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

  describe "who may download Copy 1" do
    let!(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }
    let!(:assignment) { create(:company_assignment, user: accountant, company: company, client_management: false, granted_by: admin) }

    before do
      decide("cornerstone")
      mark_ready
    end

    it "gives an accountant without client management the employee copies but not Copy 1" do
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(accountant)

      download("drt")
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("123-45-6789")

      download("employee")
      expect(response).to have_http_status(:ok), response.body
      expect(response.media_type).to eq("application/pdf")
      expect(copy_logs.map { |log| log.metadata["document_kind"] }).to eq([ "w2_gu_employee_copies_b_c" ])
    end

    it "gives Copy 1 to an accountant with client management for this client" do
      assignment.update!(client_management: true)
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(accountant)

      download("drt")

      expect(response).to have_http_status(:ok), response.body
      expect(pdf_text).to include("123-45-6789")
      expect(copy_logs.last).to have_attributes(user_id: accountant.id)
    end
  end

  describe "in a test workspace" do
    # The client is ready on its live records; then it becomes a sandbox
    # copy, carrying that ready mark with it.
    before do
      decide("cornerstone")
      mark_ready
      source = create(:company, organization: company.organization)
      company.update_columns(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
        migration_source_company_id: source.id, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)
      fingerprint = W2FilingInputsFingerprint.new(company: company.reload, year: 2026).call
      expect(W2FilingReadiness.find_by!(company: company, year: 2026).current?(fingerprint)).to be(true)
    end

    it "refuses Copy 1, which has full SSNs" do
      download("drt")

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to include("unavailable in a test workspace")
      expect(response.body).not_to include("123-45-6789")
      expect(copy_logs).to be_empty
    end

    it "sends employee copies only as a watermarked practice draft" do
      download("employee")

      expect(response).to have_http_status(:ok), response.body
      expect(response.headers["Content-Disposition"]).to include("_DRAFT.pdf")
      expect(pdf_text).to include("DRAFT — a practice copy. Do not give to employees or file.")
      expect(pdf_text).not_to include("123-45-6789")
      expect(copy_logs.last.metadata).to include("status" => "draft", "contains_full_ssn" => false)
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
