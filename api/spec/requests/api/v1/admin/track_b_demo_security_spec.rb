# frozen_string_literal: true

require "rails_helper"

# Track B step 7 negative security specs: with a demo company selected (both the
# new live+demo flag shape and the legacy test-workspace demo shape), shared
# firm configs, billing/finance, AIRE/time tracking, profitability refresh, and
# production e-file downloads are all refused fail-closed.
RSpec.describe "Track B demo company negative security gates", type: :request do
  let!(:organization) { create(:organization, client_limit: 5) }
  let!(:live) { create(:company, organization: organization, name: "Live Client", ein: "98-7654321") }
  let!(:super_admin) { create(:user, company: live, organization: organization, role: "super_admin", created_at: 1.year.ago) }
  let!(:tax_config) { create(:annual_tax_config, tax_year: 2027) }
  let!(:retirement_limit) do
    AnnualRetirementLimit.create!(
      tax_year: 2027, elective_deferral_limit: 24_500, catch_up_limit: 8_000,
      enhanced_catch_up_limit: 11_250, roth_catch_up_wage_threshold: 150_000,
      annual_additions_limit: 72_000, compensation_limit: 360_000,
      source_name: "IRS Notice", source_url: "https://www.irs.gov/retirement-plans"
    )
  end
  let!(:live_source) { create(:time_tracking_source, company: live) }

  shared_examples "refuses contained firm and external actions" do |shape_label|
    let(:demo_employee) do
      create(:employee, company: demo, department: create(:department, company: demo), ssn_encrypted: "900-01-4101")
    end
    let!(:demo_period) do
      create_committed_demo_pay_period(company: demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee)
    end

    before do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      allow_any_instance_of(ApplicationController).to receive(:current_user) { User.find(super_admin.id) }
      allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(super_admin.id)
      allow_any_instance_of(ApplicationController).to receive(:current_company_id) { demo.id }
      PayrollFilingResponsibilityRecorder.new(
        company: demo, actor: super_admin, tax_year: 2026,
        filing_types: %w[w2_gu form_1099], responsible_party: "cornerstone",
        imported_payroll_inclusion: "included", prior_provider_through: nil
      ).call
    end

    def headers
      { "X-Company-Id" => demo.id.to_s }
    end

    def expect_refused_with_demo_message
      expect(response).to have_http_status(:forbidden), "#{response.status}: #{response.body}"
      expect(response.parsed_body.fetch("error")).to eq(Company::DEMO_UNAVAILABLE_MESSAGE)
    end

    it "refuses tax configs, filing submitters and retirement limits (#{shape_label})" do
      post "/api/v1/admin/tax_configs", params: { tax_config: { tax_year: 2028 } }, headers: headers
      expect_refused_with_demo_message

      patch "/api/v1/admin/tax_configs/#{tax_config.id}", params: { tax_config: { ss_wage_base: 190_000 } }, headers: headers
      expect_refused_with_demo_message

      delete "/api/v1/admin/tax_configs/#{tax_config.id}", headers: headers
      expect_refused_with_demo_message

      patch "/api/v1/admin/filing_submitter", params: { filing_submitter: { name: "Changed Submitter" } }, headers: headers
      expect_refused_with_demo_message

      get "/api/v1/admin/annual_retirement_limits", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("can_manage")).to be(false)

      post "/api/v1/admin/annual_retirement_limits", params: {
        annual_retirement_limit: { tax_year: 2028, annual_additions_limit: 70_000, compensation_limit: 350_000, reason: "IRS notice" }
      }, headers: headers
      expect_refused_with_demo_message

      patch "/api/v1/admin/annual_retirement_limits/#{retirement_limit.id}", params: {
        annual_retirement_limit: { annual_additions_limit: 71_000, compensation_limit: 355_000, reason: "IRS notice" }
      }, headers: headers
      expect_refused_with_demo_message
    end

    it "refuses invoices and finance writes (#{shape_label})" do
      post "/api/v1/admin/invoices", params: { invoice: { company_id: demo.id } }, headers: headers
      expect_refused_with_demo_message

      post "/api/v1/admin/expenses", params: { expense: { description: "Paper", amount: 25 } }, headers: headers
      expect_refused_with_demo_message

      post "/api/v1/admin/finance_books", params: { finance_book: { name: "Blocked", legal_name: "Blocked", kind: "organization" } }, headers: headers
      expect_refused_with_demo_message

      expect(Invoice.new(organization: organization, company: demo)).not_to be_valid
      expect(InvoiceRecipient.new(organization: organization, company: demo, name: "Blocked")).not_to be_valid
      expect(FinanceBook.new(organization: organization, company: demo, name: "Blocked", legal_name: "Blocked", kind: "client")).not_to be_valid
    end

    it "refuses AIRE, time tracking and profitability refresh (#{shape_label})" do
      post "/api/v1/admin/time_tracking_sources", params: {
        time_tracking_source: { name: "AIRE", source_type: "aire_services", base_url: "https://aire.example.test", shared_secret: "secret" }
      }, headers: headers
      expect_refused_with_demo_message

      post "/api/v1/admin/time_tracking_sources/#{live_source.id}/aire_account_link", headers: headers
      expect_refused_with_demo_message

      expect(build(:time_tracking_source, company: demo)).not_to be_valid
      expect { TimeTracking::Client.new(build(:time_tracking_source, company: demo)) }
        .to raise_error(TimeTracking::Client::Error, Company::DEMO_UNAVAILABLE_MESSAGE)

      expect { post "/api/v1/admin/client_profitability/refresh", headers: headers }.not_to have_enqueued_job(TaxWorkHoursImportJob)
      expect_refused_with_demo_message
    end

    it "refuses production e-file downloads and placeholder/shared-email mutations (#{shape_label})" do
      get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }, headers: headers
      expect_refused_with_demo_message

      get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }, headers: headers
      expect_refused_with_demo_message

      get "/api/v1/admin/reports/quarterly_compliance_packet_swica_ascii", params: { year: 2026, quarter: 1 }, headers: headers
      expect_refused_with_demo_message

      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("can_clear")).to be(false)

      post "/api/v1/admin/employee_contact_hygiene/placeholder_emails", params: { email: "none@example.test", reason: "Shared" }, headers: headers
      expect_refused_with_demo_message

      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails", params: { email: "none@example.test" }, headers: headers
      expect_refused_with_demo_message
    end
  end

  context "with a new-shape live+demo flag company selected" do
    let!(:demo) { create_live_demo_company(organization: organization, ein: "98-7654321") }

    include_examples "refuses contained firm and external actions", "new-shape demo"
  end

  context "with a legacy test-workspace demo company selected" do
    let!(:demo) { create_demo_company(organization: organization, ein: "98-7654322") }

    include_examples "refuses contained firm and external actions", "legacy-shape demo"
  end
end
