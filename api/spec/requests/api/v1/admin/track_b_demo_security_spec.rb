# frozen_string_literal: true

require "rails_helper"

# Track B step 7 negative security specs: with a demo company selected via real
# X-Company-Id header resolution (both the new live+demo flag shape and the
# legacy test-workspace demo shape), shared firm configs, organization
# administration, billing/finance, AIRE/time tracking, profitability refresh,
# and non-local e-file downloads are all refused fail-closed, while paired live
# company controls proceed with the exact same valid payloads.
RSpec.describe "Track B demo company negative security gates", type: :request do
  let!(:organization) { create(:organization, client_limit: 5) }
  let!(:live) do
    create(
      :company,
      organization: organization,
      name: "Live Client",
      ein: "66-7654321",
      address_line1: "123 Marine Corps Dr",
      city: "Tamuning",
      state: "GU",
      zip: "96913",
      phone: "671-555-0100",
      email: "payroll@example.com",
      filing_contact_name: "Ana Cruz",
      kind_of_employer: "N",
      employment_code: "R"
    )
  end
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
  let!(:live_book) { FinanceBook.default_for!(organization) }
  let!(:live_recipient) { create(:invoice_recipient, organization: organization, finance_book: live_book, company: live) }
  let!(:live_period) { create(:pay_period, :committed, company: live, pay_date: Date.new(2026, 3, 6)) }

  let(:valid_submitter_params) do
    {
      profile: {
        name: "Cornerstone Payroll",
        ein: "66-1234567",
        address_line1: "238 Flores St",
        city: "Hagatna",
        state: "GU",
        zip: "96910",
        contact_name: "Pat Reyes",
        contact_phone: "671-555-0199",
        contact_email: "filings@example.com",
        bso_user_id: "TESTBS01",
        tcc: "T1234"
      }
    }
  end

  before do
    organization.update!(primary_company: live)
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(LocalDeployment).to receive(:local?).and_return(false)
    # Authenticate super_admin WITHOUT stubbing current_company_id so every
    # request exercises real X-Company-Id resolution.
    allow_any_instance_of(ApplicationController).to receive(:current_user) { User.find(super_admin.id) }
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(super_admin.id)
  end

  def headers_for(company, extra = {})
    { "X-Company-Id" => company.id.to_s }.merge(extra)
  end

  def expect_refused_with_demo_message
    expect(response).to have_http_status(:forbidden), "#{response.status}: #{response.body}"
    expect(response.parsed_body.fetch("error")).to eq(Company::DEMO_UNAVAILABLE_MESSAGE)
  end

  shared_examples "refuses contained firm and external actions" do |shape_label|
    let(:demo_employee) do
      create(
        :employee,
        company: demo,
        department: create(:department, company: demo),
        ssn_encrypted: "900-01-4101",
        address_line1: "100 Demo St",
        city: "Hagatna",
        state: "GU",
        zip: "96910"
      )
    end
    let!(:demo_period) do
      create_committed_demo_pay_period(company: demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee)
    end

    before do
      PayrollFilingResponsibilityRecorder.new(
        company: demo, actor: super_admin, tax_year: 2026,
        filing_types: %w[w2_gu form_1099], responsible_party: "cornerstone",
        imported_payroll_inclusion: "included", prior_provider_through: nil
      ).call
    end

    it "blocks shared organization mutations and admin invitations (#{shape_label})" do
      transferable_live = create(:company, organization: organization, name: "Transferable Live", ein: "66-7654329")
      clerk_double = instance_double(
        ClerkInvitationService,
        configured?: true,
        create_invitation: { success: true, invitation_id: "inv_live_1", status: "pending", url: "https://accounts.example.com/inv" }
      )
      allow(StagingMailTransport).to receive(:deliver).and_return({ success: true })
      allow(ClerkInvitationService).to receive(:new).and_return(clerk_double)

      expect {
        patch "/api/v1/admin/organizations/#{organization.id}",
              params: { organization: { client_limit: 99, status: "suspended" } },
              headers: headers_for(demo)
      }.not_to change { [ organization.reload.client_limit, organization.status ] }
      expect_refused_with_demo_message

      expect {
        post "/api/v1/admin/organizations/#{organization.id}/admin_users",
             params: { user: { name: "Blocked Admin", email: "blocked-org-admin@example.com" } },
             headers: headers_for(demo)
      }.not_to change(User, :count)
      expect_refused_with_demo_message

      expect {
        post "/api/v1/admin/organizations",
             params: { organization: { name: "Blocked Org", slug: "blocked-org-demo" } },
             headers: headers_for(demo)
      }.not_to change(Organization, :count)
      expect_refused_with_demo_message

      expect {
        post "/api/v1/admin/organizations/transfer_company",
             params: { transfer: { company_id: transferable_live.id, source_organization_id: organization.id, name: "Moved Org", slug: "moved-org-demo" } },
             headers: headers_for(demo)
      }.not_to change(Organization, :count)
      expect_refused_with_demo_message
      expect(transferable_live.reload.organization_id).to eq(organization.id)
      expect(StagingMailTransport).not_to have_received(:deliver)
      expect(ClerkInvitationService).not_to have_received(:new)

      # Paired live-company controls succeed with the same valid payloads (update, create, transfer, invite).
      patch "/api/v1/admin/organizations/#{organization.id}",
            params: { organization: { client_limit: 7 } },
            headers: headers_for(live)
      expect(response).to have_http_status(:ok), "#{response.status}: #{response.body}"
      expect(organization.reload.client_limit).to eq(7)

      expect {
        post "/api/v1/admin/organizations",
             params: { organization: { name: "Live Created Org", slug: "live-created-org-#{shape_label.parameterize}" } },
             headers: headers_for(live)
      }.to change(Organization, :count).by(1)
      expect(response).to have_http_status(:created), "#{response.status}: #{response.body}"

      expect {
        post "/api/v1/admin/organizations/transfer_company",
             params: { transfer: { company_id: transferable_live.id, source_organization_id: organization.id, name: "Transferred Live Org", slug: "transferred-live-#{shape_label.parameterize}" } },
             headers: headers_for(live)
      }.to change(Organization, :count).by(1)
      expect(response).to have_http_status(:created), "#{response.status}: #{response.body}"
      expect(transferable_live.reload.organization_id).not_to eq(organization.id)

      expect {
        post "/api/v1/admin/organizations/#{organization.id}/admin_users",
             params: { user: { name: "Live Admin", email: "live-org-admin-#{shape_label.parameterize}@example.com" } },
             headers: headers_for(live)
      }.to change(User, :count).by(1)
      expect(response).to have_http_status(:created), "#{response.status}: #{response.body}"
      expect(ClerkInvitationService).to have_received(:new)
    end

    it "refuses tax configs, filing submitters and retirement limits with paired live controls (#{shape_label})" do
      post "/api/v1/admin/tax_configs",
           params: { tax_config: { tax_year: 2028, ss_wage_base: 189_000, ss_rate: 0.062, medicare_rate: 0.0145, additional_medicare_rate: 0.009, additional_medicare_threshold: 200_000 } },
           headers: headers_for(demo)
      expect_refused_with_demo_message

      patch "/api/v1/admin/tax_configs/#{tax_config.id}",
            params: { tax_config: { ss_wage_base: 190_000 } },
            headers: headers_for(demo)
      expect_refused_with_demo_message

      delete "/api/v1/admin/tax_configs/#{tax_config.id}", headers: headers_for(demo)
      expect_refused_with_demo_message

      # Filing submitter GET reports can_edit: false for demo and true for live; PATCH uses real :profile key.
      get "/api/v1/admin/filing_submitter", headers: headers_for(demo)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("can_edit")).to be(false)

      patch "/api/v1/admin/filing_submitter", params: valid_submitter_params, headers: headers_for(demo)
      expect_refused_with_demo_message

      get "/api/v1/admin/filing_submitter", headers: headers_for(live)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("can_edit")).to be(true)

      patch "/api/v1/admin/filing_submitter", params: valid_submitter_params, headers: headers_for(live)
      expect(response).to have_http_status(:ok), "#{response.status}: #{response.body}"

      # Retirement limits GET + POST/PATCH refusal with paired live control.
      get "/api/v1/admin/annual_retirement_limits", headers: headers_for(demo)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("can_manage")).to be(false)

      limit_params = {
        annual_retirement_limit: {
          tax_year: 2028, elective_deferral_limit: 25_000, catch_up_limit: 8_000,
          enhanced_catch_up_limit: 11_250, roth_catch_up_wage_threshold: 150_000,
          annual_additions_limit: 73_000, compensation_limit: 365_000,
          source_name: "IRS Notice", source_url: "https://www.irs.gov/retirement-plans",
          reason: "Published 2028 IRS limits"
        }
      }
      post "/api/v1/admin/annual_retirement_limits", params: limit_params, headers: headers_for(demo)
      expect_refused_with_demo_message

      patch "/api/v1/admin/annual_retirement_limits/#{retirement_limit.id}",
            params: { annual_retirement_limit: { annual_additions_limit: 71_000, compensation_limit: 355_000, reason: "IRS notice" } },
            headers: headers_for(demo)
      expect_refused_with_demo_message

      post "/api/v1/admin/annual_retirement_limits", params: limit_params, headers: headers_for(live)
      expect(response).to have_http_status(:created), "#{response.status}: #{response.body}"
    end

    it "refuses invoices and finance writes with paired live controls (#{shape_label})" do
      finance_headers = { "X-Finance-Book-Id" => live_book.id.to_s }
      invoice_params = {
        invoice: {
          invoice_recipient_id: live_recipient.id,
          company_id: live.id,
          invoice_date: Date.new(2026, 3, 15).iso8601,
          due_date: Date.new(2026, 4, 14).iso8601,
          line_items: [ { description: "Payroll service", quantity: 1, unit_price: 250 } ]
        }
      }
      post "/api/v1/admin/invoices", params: invoice_params, headers: headers_for(demo, finance_headers)
      expect_refused_with_demo_message

      post "/api/v1/admin/invoices", params: invoice_params, headers: headers_for(live, finance_headers)
      expect(response).to have_http_status(:created), "#{response.status}: #{response.body}"

      expense_params = {
        expense: {
          description: "Office supplies",
          amount: 25,
          expense_date: Date.new(2026, 3, 15).iso8601,
          category: "office"
        }
      }
      post "/api/v1/admin/expenses", params: expense_params, headers: headers_for(demo, finance_headers)
      expect_refused_with_demo_message

      book_params = { finance_book: { name: "Secondary Book", legal_name: "Secondary Book LLC", kind: "organization" } }
      post "/api/v1/admin/finance_books", params: book_params, headers: headers_for(demo)
      expect_refused_with_demo_message

      post "/api/v1/admin/finance_books", params: book_params, headers: headers_for(live)
      expect(response).to have_http_status(:created), "#{response.status}: #{response.body}"

      expect(Invoice.new(organization: organization, finance_book: live_book, company: demo)).not_to be_valid
      expect(InvoiceRecipient.new(organization: organization, company: demo, name: "Blocked")).not_to be_valid
      expect(FinanceBook.new(organization: organization, company: demo, name: "Blocked", legal_name: "Blocked", kind: "client")).not_to be_valid
    end

    it "refuses AIRE cockpit/calendar, time tracking and profitability refresh (#{shape_label})" do
      post "/api/v1/admin/time_tracking_sources", params: {
        time_tracking_source: { name: "AIRE", source_type: "aire_services", base_url: "https://aire.example.test", shared_secret: "secret" }
      }, headers: headers_for(demo)
      expect_refused_with_demo_message

      post "/api/v1/admin/time_tracking_sources/#{live_source.id}/aire_account_link", headers: headers_for(demo)
      expect_refused_with_demo_message

      # Direct AIRE cockpit and calendar writes are refused fail-closed for demos.
      post "/api/v1/admin/pay_periods/#{demo_period.id}/aire_payroll_calendar/publish", headers: headers_for(demo)
      expect_refused_with_demo_message

      post "/api/v1/admin/pay_periods/#{demo_period.id}/aire_payroll_cockpit/finalize",
           params: { command_id: SecureRandom.uuid, expected_version: 1, reason: "Finalize test" },
           headers: headers_for(demo)
      expect_refused_with_demo_message

      # Paired live control reaches the real AIRE calendar handler (not the demo containment block).
      post "/api/v1/admin/pay_periods/#{live_period.id}/aire_payroll_calendar/publish", headers: headers_for(live)
      expect(response).not_to have_http_status(:forbidden)

      expect(build(:time_tracking_source, company: demo)).not_to be_valid
      expect { TimeTracking::Client.new(build(:time_tracking_source, company: demo)) }
        .to raise_error(TimeTracking::Client::Error, Company::DEMO_UNAVAILABLE_MESSAGE)

      expect { post "/api/v1/admin/client_profitability/refresh", headers: headers_for(demo) }.not_to have_enqueued_job(TaxWorkHoursImportJob)
      expect_refused_with_demo_message
    end

    it "refuses production e-file downloads and placeholder/shared-email mutations (#{shape_label})" do
      get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }, headers: headers_for(demo)
      expect_refused_with_demo_message

      get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }, headers: headers_for(demo)
      expect_refused_with_demo_message

      get "/api/v1/admin/reports/quarterly_compliance_packet_swica_ascii", params: { year: 2026, quarter: 1 }, headers: headers_for(demo)
      expect_refused_with_demo_message

      get "/api/v1/admin/employee_contact_hygiene/shared_emails", headers: headers_for(demo)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("can_clear")).to be(false)

      post "/api/v1/admin/employee_contact_hygiene/placeholder_emails", params: { email: "none@example.test", reason: "Shared" }, headers: headers_for(demo)
      expect_refused_with_demo_message

      post "/api/v1/admin/employee_contact_hygiene/clear_shared_emails", params: { email: "none@example.test" }, headers: headers_for(demo)
      expect_refused_with_demo_message

      # Paired live control succeeds for placeholder email marking.
      post "/api/v1/admin/employee_contact_hygiene/placeholder_emails", params: { email: "none@example.test", reason: "Shared desk" }, headers: headers_for(live)
      expect(response).to have_http_status(:ok), "#{response.status}: #{response.body}"
    end
  end

  context "with a new-shape live+demo flag company selected" do
    let!(:demo) { create_live_demo_company(organization: organization, ein: "66-7654321") }

    include_examples "refuses contained firm and external actions", "new-shape demo"
  end

  context "with local demo e-file downloads (DEPLOYMENT_ENV=local)" do
    let!(:demo) { create_live_demo_company(organization: organization, ein: "66-1234568") }

    before do
      allow(LocalDeployment).to receive(:local?).and_return(true)
      create(:information_return_threshold, tax_year: 2026, threshold_amount: 600)
      demo.update!(
        address_line1: "100 Marine Corps Dr",
        city: "Tamuning",
        state: "GU",
        zip: "96913",
        phone: "671-555-0144",
        email: "demo-owner@example.com",
        filing_contact_name: "Demo Owner",
        kind_of_employer: "N",
        employment_code: "R"
      )
      PayrollFilingResponsibilityRecorder.new(
        company: demo, actor: super_admin, tax_year: 2026,
        filing_types: %w[w2_gu form_1099], responsible_party: "cornerstone",
        imported_payroll_inclusion: "included", prior_provider_through: nil
      ).call
    end

    it "runs official EFW2 and Pub 1220 validators for local text downloads and keeps PDF format for PDF endpoints" do
      # Create a valid submitter FIRST so the 422s below come strictly from the
      # fictional SSN/TIN validator rather than a missing submitter profile.
      FilingSubmitter.create!(
        organization: organization,
        name: "Cornerstone Payroll",
        ein: "66-1234567",
        address_line1: "238 Flores St",
        city: "Hagatna",
        state: "GU",
        zip: "96910",
        contact_name: "Pat Reyes",
        contact_phone: "671-555-0199",
        contact_email: "filings@example.com",
        bso_user_id: "TESTBS01",
        tcc: "T1234"
      )

      # Fictional SSN 900-... triggers the official EFW2 validator instead of returning nil.
      fictional_employee = create(
        :employee,
        company: demo,
        department: create(:department, company: demo),
        ssn_encrypted: "900-01-4101",
        address_line1: "100 Demo St",
        city: "Hagatna",
        state: "GU",
        zip: "96910"
      )
      create_committed_demo_pay_period(company: demo, pay_date: Date.new(2026, 3, 6), employee: fictional_employee)

      get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }, headers: headers_for(demo)
      expect(response).to have_http_status(:unprocessable_entity), "#{response.status}: #{response.body}"
      expect(response.parsed_body.fetch("error")).to include("valid SSN required")

      # W-3SS PDF still works for demos even with fictional SSNs.
      get "/api/v1/admin/reports/w3ss_pdf", params: { year: 2026, mode: "draft" }, headers: headers_for(demo)
      expect(response).to have_http_status(:ok), "#{response.status}: #{response.body}"
      expect(response.media_type).to eq("application/pdf")
      expect(response.body.b).to start_with("%PDF".b)

      # With a valid non-900 test SSN, local demo EFW2 returns real EFW2 text bytes.
      fictional_employee.update!(ssn_encrypted: "234-56-7891")

      get "/api/v1/admin/reports/w2_gu_efw2", params: { year: 2026, mode: "draft" }, headers: headers_for(demo)
      expect(response).to have_http_status(:ok), "#{response.status}: #{response.body}"
      expect(response.media_type).to eq("text/plain")
      expect(response.body).to start_with("RA")

      # Pub 1220: fictional all-nines TIN raises official validation error instead of returning a PDF.
      contractor = create(
        :employee, :contractor,
        company: demo,
        department: create(:department, company: demo),
        ssn_encrypted: "999-99-9999",
        address_line1: "200 Demo Ave",
        city: "Tamuning",
        state: "GU",
        zip: "96913"
      )
      period = create(:pay_period, :committed, company: demo, pay_date: Date.new(2026, 4, 3))
      create(:payroll_item, pay_period: period, employee: contractor, employment_type: "contractor",
             gross_pay: BigDecimal("2500.00"), net_pay: BigDecimal("2500.00"))

      get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }, headers: headers_for(demo)
      expect(response).to have_http_status(:unprocessable_entity), "#{response.status}: #{response.body}"
      expect(response.parsed_body.fetch("error")).to include("valid SSN required")

      # 1096 totals PDF still works for demos and returns a PDF.
      get "/api/v1/admin/reports/form_1096_totals", params: { year: 2026, mode: "draft" }, headers: headers_for(demo)
      expect(response).to have_http_status(:ok), "#{response.status}: #{response.body}"
      expect(response.media_type).to eq("application/pdf")
      expect(response.body.b).to start_with("%PDF".b)

      # With a valid non-900 TIN, local demo Pub 1220 returns real ASCII Pub 1220 text, NOT a PDF.
      contractor.update!(ssn_encrypted: "234-56-7890")
      get "/api/v1/admin/reports/form_1099_pub1220", params: { year: 2026, mode: "draft" }, headers: headers_for(demo)
      expect(response).to have_http_status(:ok), "#{response.status}: #{response.body}"
      expect(response.media_type).to eq("text/plain")
      expect(response.body).to start_with("T")
      expect(response.body.b).not_to start_with("%PDF".b)
    end
  end

  context "with a legacy test-workspace demo company selected" do
    let!(:demo) { create_demo_company(organization: organization, ein: "66-7654322") }

    include_examples "refuses contained firm and external actions", "legacy-shape demo"
  end

  context "with a legacy demo company converted via DemoCompany::ConvertToFlag selected" do
    before(:context) do
      @converted_org = FactoryBot.create(:organization, client_limit: 5)
      @converted_live = FactoryBot.create(
        :company,
        organization: @converted_org,
        name: "Live Client",
        ein: "66-7654321",
        address_line1: "123 Marine Corps Dr",
        city: "Tamuning",
        state: "GU",
        zip: "96913",
        phone: "671-555-0100",
        email: "payroll@example.com",
        filing_contact_name: "Ana Cruz",
        kind_of_employer: "N",
        employment_code: "R"
      )
      @converted_admin = FactoryBot.create(:user, company: @converted_live, organization: @converted_org, role: "super_admin", created_at: 1.year.ago)
      @converted_demo = FactoryBot.create(
        :company,
        organization: @converted_org,
        name: "Converted Security Demo",
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "demo",
        migration_rehearsal_status: "ready",
        test_workspace_manifest: { "version" => 1, "purpose" => "demo", "demo_fixture_key" => "converted-security-demo" },
        auto_create_fit_check: false,
        ein: "66-7654323"
      )
      DemoCompany::ConvertToFlag.new(
        organization: @converted_org,
        actor: @converted_admin,
        company_ids: [ @converted_demo.id ],
        dry_run: false
      ).call
      @converted_demo.reload
      unless @converted_demo[:demo] == true && @converted_demo.payroll_environment == "live" && !@converted_demo.legacy_demo?
        raise "Expected converted demo shape"
      end
    end

    after(:context) do
      conn = ApplicationRecord.connection
      org_id = @converted_org&.id
      next unless org_id

      conn.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        conn.execute("DELETE FROM audit_logs WHERE organization_id = #{org_id}")
        conn.execute("DELETE FROM invoice_billing_profiles WHERE organization_id = #{org_id}")
        conn.execute("DELETE FROM finance_books WHERE organization_id = #{org_id}")
        conn.execute("DELETE FROM users WHERE organization_id = #{org_id}")
        conn.execute("DELETE FROM companies WHERE organization_id = #{org_id}")
        conn.execute("DELETE FROM organizations WHERE id = #{org_id}")
      end
    end

    let!(:organization) { @converted_org }
    let!(:live) { @converted_live }
    let!(:super_admin) { @converted_admin }
    let!(:demo) { @converted_demo }

    include_examples "refuses contained firm and external actions", "converted-shape demo"
  end
end
