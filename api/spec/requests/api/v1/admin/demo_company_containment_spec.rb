# frozen_string_literal: true

require "rails_helper"

# A demo company behaves like a live client for staff, but its committed
# payroll never reaches firm totals, official e-files, filing records,
# payments or firm billing, and its refusals read like any unavailable step.
RSpec.describe "Demo company containment", type: :request do
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  let!(:organization) { create(:organization, client_limit: 5) }
  let!(:live) { create(:company, organization: organization, name: "Live Client", ein: "98-7654321") }
  let!(:sandbox) do
    create(:company, organization: organization, name: "Live Client practice", payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: live, migration_rehearsal_status: "ready",
      test_workspace_expires_at: 30.days.from_now)
  end
  let!(:demo) { create_demo_company(organization: organization, ein: "98-7654322") }
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin", created_at: 1.year.ago) }
  let(:live_employee) { create(:employee, company: live, department: create(:department, company: live)) }
  let(:demo_employee) { create(:employee, company: demo, department: create(:department, company: demo), ssn_encrypted: "900-01-0002") }
  let(:selected_company) { demo }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user) { User.find(admin.id) }
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(admin.id)
    allow_any_instance_of(ApplicationController).to receive(:current_company_id) { selected_company.id }
    create_committed_demo_pay_period(company: live, pay_date: Date.new(2026, 3, 6), employee: live_employee)
  end

  def firm_totals
    overview = YearEnd::ClientsOverview.new(user: User.find(admin.id), year: 2026).call
    {
      live_client_count: organization.companies.live_payroll.count,
      year_end_clients: overview[:clients].map { |row| row[:name] }.sort,
      year_end_counts: overview[:counts],
      year_end_hidden: overview[:hidden],
      profitability_companies: ClientProfitability::LinkQueue.new(organization: organization).send(:companies).map(&:id),
      inbox_summary: ClientInboxQuery.new(user: admin).summary
    }
  end

  # Demo client logins arrive with demo access (D5); bind a fixture author directly.
  def demo_client_message!
    author = create(:user, company: live, organization: organization, role: "client")
    author.update_columns(company_id: demo.id)
    thread = create(:client_portal_thread, company: demo, created_by: author)
    create(:client_portal_message, company: demo, client_portal_thread: thread, author: author)
  end

  it "leaves firm-wide totals unchanged when a demo payroll is committed" do
    before = firm_totals
    create_committed_demo_pay_period(company: demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee, gross_pay: 9_000)
    demo_client_message!

    expect(firm_totals).to eq(before)
    expect(before[:year_end_clients]).to eq([ "Live Client" ])
    expect(before[:year_end_hidden][:test_workspaces]).to eq(1)
    expect(before[:profitability_companies]).to eq([ live.id ])
  end

  it "shows demo inbox activity only when the demo client is selected, and never in the badge" do
    demo_client_message!

    get "/api/v1/admin/client_inbox"
    expect(response.parsed_body.fetch("data")).to be_empty
    get "/api/v1/admin/client_inbox", params: { company_id: demo.id }
    expect(response.parsed_body.fetch("data").sole).to include("company_id" => demo.id, "practice_copy" => false)
    get "/api/v1/admin/client_inbox/counts"
    expect(response.parsed_body.values.grep(Integer).sum).to eq(0)
    get "/api/v1/admin/client_inbox/counts", params: { company_id: demo.id }
    expect(response.parsed_body.values.grep(Integer).sum).to eq(0)
  end

  it "keeps a demo out of profitability, billing and firm books with a neutral reason" do
    expect(ClientProfitabilitySetting.new(organization: organization, practice_company: demo)).not_to be_valid
    expect(WorkHourClientLink.new(organization: organization, company: demo, tax_client_id: 1, disposition: "company")).not_to be_valid

    recipient = InvoiceRecipient.new(organization: organization, company: demo, name: "Harbor Finch Kitchen")
    expect(recipient).not_to be_valid
    expect(recipient.errors.full_messages).to include(Company::DEMO_UNAVAILABLE_MESSAGE)
    invoice = Invoice.new(organization: organization, company: demo)
    invoice.valid?
    expect(invoice.errors.full_messages).to include(Company::DEMO_UNAVAILABLE_MESSAGE)
    book = FinanceBook.new(organization: organization, company: demo, name: "Demo", legal_name: "Demo", kind: "client")
    book.valid?
    expect(book.errors.full_messages).to include(Company::DEMO_UNAVAILABLE_MESSAGE)
  end

  it "never records filing evidence for a demo, even through the service" do
    expect do
      PayrollFilingEvidenceRecorder.new(company: demo, actor: admin, evidence_document: nil, attributes: {
        filing_type: "w2_gu_w3_ss", agency: "ssa", tax_year: 2026, status: "submitted", confirmation_number: "CONF"
      }).call
    end.to raise_error(PayrollFilingEvidenceRecorder::Error, Company::DEMO_UNAVAILABLE_MESSAGE)
    expect(PayrollFilingRecord.where(company: demo)).to be_empty
  end

  it "does not precompute a demo's e-file check" do
    expect(YearEnd::Checklist).not_to receive(:new)
    YearEndEfileCheckJob.perform_now(demo.id, 2026, YearEnd::InputRevision.for(demo.id, 2026)[demo.id])
  end

  describe "requests in the demo's context" do
    let!(:period) { create_committed_demo_pay_period(company: demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee) }
    let(:draft) { create(:pay_period, company: demo, start_date: Date.new(2026, 3, 9), end_date: Date.new(2026, 3, 22), pay_date: Date.new(2026, 3, 27)) }

    before do
      PayrollFilingResponsibilityRecorder.new(company: demo, actor: admin, tax_year: 2026, filing_types: %w[w2_gu form_1099],
        responsible_party: "cornerstone", imported_payroll_inclusion: "included", prior_provider_through: nil).call
    end

    def expect_pdf_download
      expect(response).to have_http_status(:ok), response.body
      expect(response.media_type).to eq("application/pdf")
      expect(response.body).to start_with("%PDF")
    end

    def expect_neutral_refusal
      expect(response).to have_http_status(:forbidden).or have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq(Company::DEMO_UNAVAILABLE_MESSAGE)
    end

    it "refuses e-files, filing records, FIT deposit checks, shared config and billing" do
      get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }
      expect_neutral_refusal
      get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }
      expect_neutral_refusal
      get "/api/v1/admin/reports/quarterly_compliance_packet_swica_ascii", params: { year: 2026, quarter: 1 }
      expect_neutral_refusal
      post "/api/v1/admin/payroll_filing_records/events", params: { filing_type: "w2_gu_w3_ss", agency: "ssa", tax_year: 2026 }
      expect_neutral_refusal
      post "/api/v1/admin/pay_periods/#{period.id}/generate_fit_check"
      expect_neutral_refusal
      post "/api/v1/admin/invoices", params: { invoice: { company_id: demo.id } }
      expect_neutral_refusal
      patch "/api/v1/admin/filing_submitter", params: { filing_submitter: { name: "Changed" } }
      expect_neutral_refusal

      expect(period.reload.status).to eq("committed")
      expect(NonEmployeeCheck.where(company: demo)).to be_empty
      expect(PayrollFilingRecord.where(company: demo)).to be_empty
      expect(Invoice.where(company: demo)).to be_empty
    end

    it "prints a demo check on plain paper, and refuses the rehearsal preview, an org-wide Tax refresh and shared-email clearing" do
      item = period.payroll_items.first
      item.update_columns(check_number: "1001", payment_delivery_method: "paper_check")
      get "/api/v1/admin/payroll_items/#{item.id}/check"
      expect_pdf_download
      draft.update_columns(status: "calculated")
      get "/api/v1/admin/pay_periods/#{draft.id}/checks/rehearsal_preview_pdf"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to match(/%PDF/)
      expect { post "/api/v1/admin/client_profitability/refresh" }.not_to have_enqueued_job(TaxWorkHoursImportJob)
      expect_neutral_refusal
      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails", headers: { "X-Company-Id" => demo.id.to_s }
      expect_neutral_refusal
    end

    it "renders a demo's 1096 totals from the signed-off payees without a firm transmitter" do
      create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000)
      expect(FilingSubmitter.where(organization_id: organization.id)).to be_empty
      get "/api/v1/admin/reports/form_1096_totals", params: { year: 2026, mode: "draft" }
      expect_pdf_download
    end

    it "lists only live clients as billing choices while navigation stays neutral" do
      get "/api/v1/companies"
      body = response.parsed_body
      expect(body.fetch("billing_company_ids")).to contain_exactly(live.id)
      expect(body.fetch("companies").map { |company| company["id"] }).to include(demo.id)
    end

    it "keeps the same e-files blocked for a practice copy with its existing message" do
      allow_any_instance_of(ApplicationController).to receive(:current_company_id).and_return(sandbox.id)
      get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to include("test workspace")
      get "/api/v1/admin/reports/w3ss_pdf", params: { year: 2026, mode: "draft" }
      expect(response).to have_http_status(:forbidden)
    end

    it "lets review downloads and checklist steps through like a live client" do
      get "/api/v1/admin/reports/w3ss_pdf", params: { year: 2026, mode: "draft" }
      expect_pdf_download

      get "/api/v1/admin/reports/w2_gu_employee_copies", params: { year: 2026 }
      expect_pdf_download

      get "/api/v1/admin/reports/w2_gu_copy_1_drt", params: { year: 2026 }
      expect_pdf_download

      get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: period.id }
      expect(response).to have_http_status(:ok), response.body
      report = response.parsed_body.fetch("report")
      expect(report.dig("meta", "provisional")).to be(false)
      expect(report.dig("meta", "payroll_status_note")).to be_nil
      expect(report.dig("source", "label")).to eq("Cornerstone")
      expect(response.body).not_to match(/TEST ONLY|practice copy|test workspace/i)
    end
  end

  describe "Form 500 for a demo" do
    let!(:period) { create_committed_demo_pay_period(company: demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee) }
    let(:assigned) { create(:user, company: live, organization: organization, role: "accountant") }
    let(:unassigned) { create(:user, company: live, organization: organization, role: "accountant") }

    # A demo follows the normal staff rules: the client's assigned accountant
    # works on it, and no one can record a filing or payment for it.
    before { CompanyAssignment.create!(user: assigned, company: demo) }

    def act_as(user)
      allow_any_instance_of(ApplicationController).to receive(:current_user) { User.find(user.id) }
      allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(user.id)
    end

    it "lets the assigned accountant prepare and download, never file or pay, and keeps others out" do
      act_as(unassigned)
      post "/api/v1/form_500s/save", params: { form_500: { pay_period_id: period.id, status: "prepared" } }
      expect(response).to have_http_status(:forbidden)

      act_as(assigned)
      post "/api/v1/form_500s/download", params: { form_500: { pay_period_id: period.id } }
      expect(response).to have_http_status(:ok), response.body
      expect(response.media_type).to eq("application/pdf")
      expect(response.body).to start_with("%PDF")
      post "/api/v1/form_500s/save", params: { form_500: { pay_period_id: period.id, status: "filed", payment_amount: "125.00",
        confirmation_number: "DRT-123", receipt_attached: true } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include(Company::DEMO_UNAVAILABLE_MESSAGE)
      post "/api/v1/form_500s/save", params: { form_500: { pay_period_id: period.id, status: "prepared" } }
      expect(response).to have_http_status(:ok), response.body
      expect(Form500Filing.find_by!(pay_period: period)).to have_attributes(status: "prepared", payment_amount: nil, confirmation_number: nil)
    end
  end
end
