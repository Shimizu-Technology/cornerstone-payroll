# frozen_string_literal: true

require "rails_helper"

# Track B (Expand phase) specs covering dual-shape reads (legacy demo + new live+demo
# flag), Company scopes/predicates, step 5 lifted workflows, and step 6 specific fixes.
RSpec.describe "Track B demo flag expand phase", type: :model do
  let!(:organization) { create(:organization, client_limit: 5) }
  let!(:live) { create(:company, organization: organization, name: "Live Client", ein: "98-7654321") }
  let!(:sandbox) do
    create(:company, organization: organization, name: "Practice Copy", payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: live, migration_rehearsal_status: "ready",
      test_workspace_expires_at: 30.days.from_now)
  end
  let!(:legacy_demo) { create_demo_company(organization: organization, name: "Legacy Demo", fixture_key: "legacy-demo") }
  let!(:live_demo) { create_live_demo_company(organization: organization, name: "Flagged Demo", fixture_key: "flagged-demo", ein: "98-7654321") }
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin", created_at: 1.year.ago) }

  describe "scopes, predicates and schema constraints" do
    it "classifies real live clients, practice copies, legacy demos and new-shape demos cleanly" do
      expect(live).to be_live_payroll
      expect(live).to be_operating
      expect(live).not_to be_demo
      expect(live).not_to be_contained
      expect(live).not_to be_practice_copy

      expect(sandbox).not_to be_live_payroll
      expect(sandbox).not_to be_operating
      expect(sandbox).not_to be_demo
      expect(sandbox).to be_contained
      expect(sandbox).to be_practice_copy

      [ legacy_demo, live_demo ].each do |demo|
        expect(demo).to be_demo
        expect(demo).to be_operating
        expect(demo).to be_contained
        expect(demo).not_to be_live_payroll
        expect(demo).not_to be_practice_copy
      end
      expect(legacy_demo).to be_test_workspace
      expect(legacy_demo).to be_legacy_demo
      expect(live_demo).not_to be_test_workspace
      expect(live_demo).not_to be_legacy_demo

      expect(Company.where(organization: organization).live_payroll).to contain_exactly(live)
      expect(Company.where(organization: organization).demo).to contain_exactly(legacy_demo, live_demo)
      expect(Company.where(organization: organization).not_demo).to contain_exactly(live, sandbox)
      expect(Company.where(organization: organization).operating).to contain_exactly(live, legacy_demo, live_demo)
      expect(Company.where(organization: organization).contained).to contain_exactly(sandbox, legacy_demo, live_demo)
    end

    it "enforces demo => live in validation and in the database" do
      invalid = build(:company, organization: organization, payroll_environment: "migration_rehearsal", demo: true,
        test_workspace_purpose: "sandbox", migration_source_company: live, migration_rehearsal_status: "ready")
      expect(invalid).not_to be_valid
      expect(invalid.errors[:demo]).to include("requires a live payroll environment")

      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            INSERT INTO companies (organization_id, name, payroll_environment, demo, created_at, updated_at)
            VALUES (#{organization.id}, 'Invalid Non-Live Demo', 'migration_rehearsal', TRUE, NOW(), NOW())
          SQL
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /companies_demo_requires_live_payroll/)
    end

    it "keeps EIN unique across live clients while excluding demos from the unique index and validation" do
      duplicate_live = build(:company, organization: organization, name: "Second Live", ein: "98-7654321")
      expect(duplicate_live).not_to be_valid
      expect(duplicate_live.errors[:ein]).to be_present

      second_demo = create_live_demo_company(organization: organization, name: "Second Demo", fixture_key: "second-demo", ein: "98-7654321")
      expect(second_demo).to be_persisted
    end

    it "rejects test-workspace columns on a new-shape demo and blocks flipping the demo flag" do
      live_demo.migration_rehearsal_status = "ready"
      expect(live_demo).not_to be_valid
      expect(live_demo.errors[:base]).to include("Production clients cannot reference a test workspace source")

      live_demo.reload.demo = false
      expect(live_demo).not_to be_valid
      expect(live_demo.errors[:base]).to include("A demo company cannot be converted to or from another company type")

      live.demo = true
      expect(live).not_to be_valid
      expect(live.errors[:base]).to include("A demo company cannot be converted to or from another company type")
    end

    it "still refuses preprinted MICR bank stock for new-shape demos while allowing plain paper and FIT auto-checks" do
      live_demo.check_stock_type = "first_hawaiian_4up"
      expect(live_demo).not_to be_valid
      expect { FirstHawaiianFourUpCheckGenerator.new(company: live_demo, payroll_items: []) }
        .to raise_error(ArgumentError, Company::DEMO_UNAVAILABLE_MESSAGE)

      live_demo.reload.assign_attributes(check_stock_type: "top_check", auto_create_fit_check: true)
      expect(live_demo).to be_valid
    end
  end

  describe "step 6 specific fixes" do
    let(:allowlisted_email) { "demo-client@demo-mail.example" }

    around do |example|
      saved = ENV[DemoOutbound::ENV_KEY]
      ENV[DemoOutbound::ENV_KEY] = allowlisted_email
      example.run
    ensure
      ENV[DemoOutbound::ENV_KEY] = saved
    end

    it "supports demo client logins on new-shape demos while still enforcing DemoOutbound and live/demo separation" do
      expect(build(:user, company: live_demo, organization: organization, role: "client", email: "outside@client.example")).not_to be_valid

      demo_user = create(:user, company: live_demo, organization: organization, role: "client", email: allowlisted_email)
      CompanyAssignment.create!(user: demo_user, company: live_demo)
      expect(User.find(demo_user.id).accessible_company_ids).to eq([ live_demo.id ])
      expect(CompanyAssignment.new(user: demo_user, company: live)).not_to be_valid
    end

    it "excludes new-shape demos from InvoiceServiceFeeRevenue live_clients_only" do
      book = organization.finance_books.first
      live_invoice = create(:invoice, organization: organization, finance_book: book, company: live, status: "draft",
        invoice_date: Date.new(2026, 3, 15))
      live_invoice.line_items.create!(item_name: "Payroll Fee", description: "Monthly payroll", quantity: 1, rate: 500, line_kind: "service_fee", position: 1)
      live_invoice.update_columns(status: "open", total_amount: 500)

      # Bypass model validation to simulate a stale demo-linked invoice row.
      stale_demo_invoice = create(:invoice, organization: organization, finance_book: book, company: live, status: "draft",
        invoice_date: Date.new(2026, 3, 15))
      stale_demo_invoice.line_items.create!(item_name: "Payroll Fee", description: "Monthly payroll", quantity: 1, rate: 900, line_kind: "service_fee", position: 1)
      stale_demo_invoice.update_columns(company_id: live_demo.id, status: "open", total_amount: 900)

      rows = InvoiceServiceFeeRevenue.call(finance_book: book, live_clients_only: true)
      expect(rows.map { |r| r[:company_id] }).to eq([ live.id ])
      expect(rows.sole[:amount]).to eq(BigDecimal("500"))
    end

    it "excludes new-shape demos from org-wide shared email report and inbox counters while keeping inbox rows" do
      demo_dept = create(:department, company: live_demo)
      2.times { create(:employee, company: live_demo, department: demo_dept, email: "shared@demo-kitchen.example") }

      org_report = EmployeeContactHygiene::SharedEmailReport.new(actor: admin, organization_id: organization.id).call
      expect(org_report[:companies].map { |c| c[:company_id] }).not_to include(live_demo.id)

      demo_user = create(:user, company: live_demo, organization: organization, role: "client", email: allowlisted_email)
      thread = create(:client_portal_thread, company: live_demo, created_by: demo_user)
      create(:client_portal_message, company: live_demo, client_portal_thread: thread, author: demo_user)

      query = ClientInboxQuery.new(user: admin)
      expect(query.page[:data].map { |r| [ r[:company_id], r[:demo] ] }).to include([ live_demo.id, true ])
      expect(query.summary.values.sum).to eq(0)
    end

    it "backfills operating profiles for operating companies (live + demos) and skips practice copies" do
      result = ClientOperatingProfiles::BackfillService.call
      expect(result[:created]).to be >= 3
      expect(live.client_operating_profiles.exists?).to be(true)
      expect(live_demo.client_operating_profiles.exists?).to be(true)
      expect(legacy_demo.client_operating_profiles.exists?).to be(true)
      expect(sandbox.client_operating_profiles.exists?).to be(false)
    end

    it "excludes inactive demos from Year-End hidden inactive_without_payroll counts and firm totals" do
      inactive_demo = create_live_demo_company(organization: organization, name: "Inactive Demo", fixture_key: "inactive-demo", active: false)
      overview = YearEnd::ClientsOverview.new(user: admin, year: 2026).call
      names = overview[:clients].map { |row| row[:name] }
      expect(names).to include("Live Client", "Flagged Demo", "Legacy Demo")
      expect(names).not_to include(inactive_demo.name, sandbox.name)
      expect(overview[:clients].find { |row| row[:company_id] == live_demo.id }[:demo]).to be(true)
      expect(overview[:clients].find { |row| row[:company_id] == live.id }[:demo]).to be(false)
      expect(overview[:counts][:needs_action]).to eq(1)
      expect(overview[:hidden][:inactive_without_payroll]).to eq(0)
      expect(overview[:hidden][:test_workspaces]).to eq(1)
    end
  end

  describe "step 5 lifted workflows on new-shape demos" do
    let!(:tax_table) { create(:tax_table, tax_year: 2026) }
    let(:department) { create(:department, company: live_demo) }
    let(:employee) { create(:employee, company: live_demo, department: department, ssn_encrypted: "900-01-5001", payment_delivery_method: "paper_check") }

    it "allows contractors, Form 500 outcomes, filing records, liability postings, FIT/non-employee checks, register list and prior-provider tools" do
      # Contractors
      contractor = create(:employee, company: live_demo, department: department, employment_type: "contractor",
        contractor_type: "individual", contractor_pay_type: "flat_fee", ssn_encrypted: "900-01-5002")
      expect(contractor).to be_persisted

      # Register list shows committed runs only (F10)
      draft = create(:pay_period, company: live_demo, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 14), pay_date: Date.new(2026, 2, 20), status: "calculated")
      expect(PriorProviderHistory::Discovery.available?(live_demo, period: draft)).to be(true)
      expect(PriorProviderHistory::Discovery.available?(sandbox)).to be(false)

      committed = create_committed_demo_pay_period(company: live_demo, pay_date: Date.new(2026, 3, 6), employee: employee)
      register_ids = PayrollHistoryQuery.new(company_id: live_demo.id, params: { register_eligible: true }).call.data.map { |row| row[:id] }
      expect(register_ids).to contain_exactly(committed.id)

      # Form 500 outcomes
      form500 = Form500Filing.create!(company: live_demo, pay_period: committed, fields: { "company_name" => live_demo.name },
        status: "filed", payment_amount: 150, payment_date: Date.new(2026, 3, 15), confirmation_number: "DRT-DEMO-1", receipt_attached: true)
      expect(form500).to be_persisted

      # Liability postings & reversal
      posting = PayrollLiabilityPostingService.post!(pay_period: committed, actor: admin)
      expect(posting).to be_persisted
      expect(PayrollLiabilityPosting.where(company: live_demo)).to exist

      # FIT deposit / non-employee checks on plain paper
      fit_check = NonEmployeeCheck.create!(company: live_demo, pay_period: committed, payable_to: "Treasurer of Guam",
        amount: 150, check_type: "tax_deposit", payment_period_type: "pay_period", payment_date: committed.pay_date, created_by: admin)
      expect(fit_check).to be_persisted
      expect(NonEmployeeCheckGenerator.new(fit_check).generate).to start_with("%PDF")

      # Filing records & Year-End filing progress
      PayrollFilingResponsibilityRecorder.new(company: live_demo, actor: admin, tax_year: 2026, filing_types: %w[w2_gu],
        responsible_party: "cornerstone", imported_payroll_inclusion: "included", prior_provider_through: nil).call
      record = PayrollFilingRecord.create!(company: live_demo, filing_type: "w2_gu_w3_ss", agency: "ssa", tax_year: 2026,
        status: "submitted", submitted_at: Time.current, confirmation_number: "DEMO-CONF", source_fingerprint: "a" * 64)
      expect(record).to be_persisted
      progress = YearEnd::FilingProgress.new(company: live_demo, year: 2026).call
      expect(progress.find { |entry| entry[:agency] == "ssa" }[:status]).to eq("submitted")
    end

    it "keeps practice copies blocked on prior-provider tools and filing progress" do
      expect(YearEnd::FilingProgress.new(company: sandbox, year: 2026).call).to eq([])
      plan = PriorProviderHistory::Plan.new(company: sandbox, payload: {
        "identities" => {}, "periods" => [ { "key" => "p1", "paychecks" => [ { "employee_id" => 1 } ] } ]
      }).call
      expect(plan.errors).to include("Prior-provider onboarding requires a live client")
    end
  end

  describe "dual-shape database guards (HIGH 2)" do
    it "refuses validation-skipping SQL that flips demo identity on or off" do
      expect {
        ActiveRecord::Base.transaction(requires_new: true) { Company.where(id: live_demo.id).update_all(demo: false) }
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)
      expect(live_demo.reload.demo?).to be(true)

      expect {
        ActiveRecord::Base.transaction(requires_new: true) { Company.where(id: live.id).update_all(demo: true) }
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)
      expect(live.reload.demo?).to be(false)

      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          Company.where(id: live_demo.id).update_all(test_workspace_manifest: { "demo_fixture_key" => "tampered-key" })
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo fixture keys are immutable/)
    end

    it "refuses validation-skipping time_tracking_sources inserts and updates for both demo shapes" do
      live_source = create(:time_tracking_source, company: live)

      [ live_demo, legacy_demo ].each do |demo_company|
        expect {
          ActiveRecord::Base.transaction(requires_new: true) do
            TimeTrackingSource.insert_all!([ {
              company_id: demo_company.id,
              name: "Bypassed AIRE",
              source_type: "aire_services",
              base_url: "https://aire.example.test",
              shared_secret: "secret",
              active: true,
              created_at: Time.current,
              updated_at: Time.current
            } ])
          end
        }.to raise_error(ActiveRecord::StatementInvalid, /time_tracking_sources cannot belong to a demo company/)

        expect {
          ActiveRecord::Base.transaction(requires_new: true) do
            TimeTrackingSource.where(id: live_source.id).update_all(company_id: demo_company.id)
          end
        }.to raise_error(ActiveRecord::StatementInvalid, /time_tracking_sources cannot belong to a demo company/)
      end
    end
  end
end
