# frozen_string_literal: true

require "rails_helper"
require "rake"
require "tmpdir"

RSpec.describe DemoCompany::VerifyShapeMigration do
  # Exercises real PostgreSQL SET TRANSACTION READ ONLY enforcement and
  # nested-transaction refusal on every capture.
  self.use_transactional_tests = false

  let!(:created_organization_ids) { [] }
  let!(:organization) do
    create(:organization, client_limit: 5).tap { |org| created_organization_ids << org.id }
  end
  let!(:live) { create(:company, organization: organization, name: "Live Client", ein: "66-7654321") }
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin", created_at: 1.year.ago) }
  let!(:owner) { create(:user, company: live, organization: organization, role: "super_admin", created_at: 1.year.ago) }
  let!(:old_demo) do
    create_demo_company(
      organization: organization,
      name: "Harbor Finch Kitchen",
      fixture_key: "harbor-finch-kitchen",
      subdomain_slug: "harborfinch",
      ein: "66-7654321",
      migration_rehearsal_created_by: admin,
      migration_rehearsal_created_at: Time.utc(2026, 11, 20, 10, 0, 0),
      migration_rehearsal_completed_at: Time.utc(2026, 11, 20, 10, 5, 0),
      migration_rehearsal_error: "Sensitive internal detail that must never appear raw"
    )
  end
  let(:client_email) { "reviewer+manager@demo-mail.example" }
  let(:employee_email) { "reviewer+emp01@demo-mail.example" }
  let!(:demo_department) { create(:department, company: old_demo) }
  let!(:demo_employee) do
    create(
      :employee,
      company: old_demo,
      department: demo_department,
      first_name: "Employee",
      last_name: "01",
      email: employee_email,
      ssn_encrypted: "900-01-5101",
      address_line1: "100 Harbor Way",
      city: "Hagatna",
      state: "GU",
      zip: "96910",
      payment_delivery_method: "direct_deposit"
    )
  end
  let!(:demo_client_user) do
    create(:user, role: :client, company: old_demo, organization: organization, email: client_email).tap do |user|
      CompanyAssignment.create!(user: user, company: old_demo)
    end
  end
  let!(:demo_portal_user) do
    create(:user, role: :portal_employee, company: old_demo, organization: organization, email: employee_email)
  end
  let!(:active_link) do
    EmployeeAccountLink.create!(
      company: old_demo, employee: demo_employee, user: demo_portal_user,
      status: "active", activated_at: 1.day.ago
    )
  end
  let!(:early_access_window) do
    EmployeeAppEarlyAccessWindow.create!(
      organization: organization,
      company_ids: [ old_demo.id ],
      expires_on: PayrollBusinessClock.today + 14,
      reason: "Demo early access",
      set_by: owner
    )
  end
  let(:shadow_state) { { phase: "shadow", enforced: false, kill_switch_bypass: false, enforced_tables: 0, protected_tables: 1 } }
  let(:enforced_state) { { phase: "enforced", enforced: true, kill_switch_bypass: false, enforced_tables: 1, protected_tables: 1 } }
  let(:stored_pdfs) { {} }
  let(:storage) { instance_double(R2StorageService) }

  around do |example|
    saved = ENV[DemoOutbound::ENV_KEY]
    ENV[DemoOutbound::ENV_KEY] = [ client_email, employee_email ].join(",")
    example.run
  ensure
    ENV[DemoOutbound::ENV_KEY] = saved
  end

  before do
    DeliveryDisclosures::DraftSeeds.seed!
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(shadow_state)
    allow(EmployeeAppSwitch::Enforcement).to receive(:current_process_guarded?).and_return(true)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:upload) { |key, bytes, **| stored_pdfs[key] = bytes.dup.b }
    allow(storage).to receive(:download) { |key| stored_pdfs[key] }
    allow(storage).to receive(:delete) { |key| stored_pdfs.delete(key) }

    old_demo.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today - 30,
      version: 1,
      offering: "payroll_portals",
      hours_source: "manual",
      client_portal_enabled: true,
      employee_portal_enabled: true,
      options: {
        "subdomain_enabled" => true,
        "employee_portal" => { "features" => %w[stubs tax_forms profile_requests delivery_consent].index_with(true) }
      }
    )
    activate_employee_app!(old_demo, actor: admin)

    thread = create(:client_portal_thread, company: old_demo, created_by: demo_client_user)
    create(:client_portal_message, company: old_demo, client_portal_thread: thread, author: demo_client_user)

    book = organization.finance_books.first
    live_invoice = create(:invoice, organization: organization, finance_book: book, company: live, status: "draft", invoice_date: Date.new(2026, 3, 15))
    live_invoice.line_items.create!(item_name: "Payroll Fee", description: "Monthly", quantity: 1, rate: 500, line_kind: "service_fee", position: 1)
    live_invoice.update_columns(status: "open", total_amount: 500)

    period = create_committed_demo_pay_period(company: old_demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee)
    period.update_columns(committed_at: 2.days.ago)
    item = period.payroll_items.sole
    item.update_columns(payment_delivery_method: "direct_deposit")
    EmployeeYtdTotal.create!(employee: demo_employee, year: 2026, gross_pay: 2_000, net_pay: 1_600)
    CompanyYtdTotal.create!(company: old_demo, year: 2026, gross_pay: 2_000, net_pay: 1_600)
    EmployeeDocuments::PostPayStub.new(item, now: Time.current).call
  end

  after do
    conn = ApplicationRecord.connection
    ids = created_organization_ids.uniq
    next if ids.empty?

    conn.transaction do
      conn.execute("SET LOCAL session_replication_role = replica")
      company_ids = conn.select_values("SELECT id FROM companies WHERE organization_id IN (#{ids.join(',')})")
      if company_ids.any?
        c_list = company_ids.join(",")
        %w[
          employee_documents employee_ytd_totals company_ytd_totals payroll_items pay_periods
          client_portal_messages client_portal_threads employee_app_activations client_operating_profiles
          employee_account_links company_assignments employees departments demo_shape_conversions audit_logs
        ].each do |table|
          conn.execute("DELETE FROM #{table} WHERE company_id IN (#{c_list})")
        end
      end
      o_list = ids.join(",")
      invoice_ids = conn.select_values("SELECT id FROM invoices WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM invoice_line_items WHERE invoice_id IN (#{invoice_ids.join(',')})") if invoice_ids.any?
      conn.execute("DELETE FROM invoices WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM invoice_billing_profiles WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM finance_books WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM employee_app_early_access_windows WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM audit_logs WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM users WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM companies WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM organizations WHERE id IN (#{o_list})")
    end
  end

  it "refuses to run inside an existing transaction and never writes even when RLS enforcement is verified" do
    expect {
      ApplicationRecord.transaction do
        described_class.capture(organization: organization, actor: admin, company_ids: [ old_demo.id ], tax_year: 2026)
      end
    }.to raise_error(described_class::Error, /existing database transaction/)

    # Even when Enforcement reports verified/enforced, capture must NOT retire early_access_window or write an audit log,
    # and must run inside a single REPEATABLE READ, READ ONLY transaction.
    allow(EmployeeAppSwitch::Enforcement).to receive(:database_state).and_return(enforced_state)
    allow(EmployeeAppSwitch::Enforcement).to receive(:verified?).and_return(true)

    observed_tx = nil
    expect {
      described_class.capture(
        organization: organization,
        actor: admin,
        company_ids: [ old_demo.id ],
        tax_year: 2026,
        readiness_database_state: lambda {
          observed_tx = ApplicationRecord.connection.select_one(
            "SELECT current_setting('transaction_isolation') AS iso, current_setting('transaction_read_only') AS ro"
          )
          enforced_state
        }
      )
    }.not_to change(AuditLog, :count)
    expect(observed_tx).to eq("iso" => "repeatable read", "ro" => "on")
    expect(early_access_window.reload.retired_at).to be_nil
  end

  it "captures all verification areas read-only (hashing migration_rehearsal_error, including paid-correction & history evidence) and reports zero unexpected diffs after ConvertToFlag" do
    before_snapshot = nil
    expect {
      before_snapshot = described_class.capture(
        organization: organization,
        actor: admin,
        company_ids: [ old_demo.id ],
        tax_year: 2026,
        readiness_database_state: -> { shadow_state }
      )
    }.not_to have_enqueued_job(YearEndEfileCheckJob)

    # Never emit raw migration_rehearsal_error text (LOW 1).
    expect(JSON.generate(before_snapshot)).not_to include("Sensitive internal detail")

    entry = before_snapshot.fetch("companies").fetch(old_demo.id.to_s)
    expect(entry.dig("shape", "company", "demo")).to be(false)
    expect(entry.dig("shape", "company", "payroll_environment")).to eq("migration_rehearsal")
    expect(entry.dig("shape", "company", "migration_rehearsal_error_present")).to be(true)
    expect(entry.dig("shape", "company", "migration_rehearsal_error_sha256")).to match(/\A[0-9a-f]{64}\z/)
    expect(entry.dig("shape", "employee_account_links_payroll_environments", active_link.id.to_s)).to eq("migration_rehearsal")
    expect(entry.dig("subdomain", "enabled_origin_company_id")).to eq(old_demo.id)
    expect(entry.dig("counters", "client_caps", "in_live_payroll_scope")).to be(false)
    expect(entry.dig("counters", "inbox", "organization_summary").values.sum).to eq(0)
    expect(entry.dig("counters", "inbox", "company_visible_in_inbox")).to be(true)
    expect(entry.dig("counters", "year_end", "listed")).to be(true)
    expect(entry.dig("counters", "year_end", "demo_flag")).to be(true)
    expect(entry.dig("ein_uniqueness", "in_live_ein_unique_index")).to be(false)
    expect(entry.dig("ein_uniqueness", "live_company_ids_sharing_ein")).to eq([ live.id ])
    expect(entry.dig("payroll_checksums", "posted_documents_count")).to eq(1)
    expect(entry.dig("payroll_checksums", "all_posted_stubs_match_stored_fingerprint")).to be(true)
    expect(entry.dig("payroll_checksums", "paid_correction_evidence_sha256")).to match(/\A[0-9a-f]{64}\z/)
    expect(entry.dig("payroll_checksums", "time_tracking_history")).to include(
      "sources_count" => 0,
      "history_reviews_count" => 0,
      "verified_history_receipts_count" => 0
    )

    DemoCompany::ConvertToFlag.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call

    after_snapshot = described_class.capture(
      organization: organization,
      actor: admin,
      company_ids: [ old_demo.id ],
      tax_year: 2026,
      readiness_database_state: -> { shadow_state }
    )

    diff = described_class.diff(before_snapshot, after_snapshot, expected_company_ids: [ old_demo.id ])
    expect(diff.unexpected_diffs).to eq([])
    expect(diff).to be_passed

    changed_paths = diff.shape_changes.fetch(old_demo.id.to_s).map { |change| change[:path] }
    expect(changed_paths).to include(
      "companies.#{old_demo.id}.shape.company.demo",
      "companies.#{old_demo.id}.shape.company.payroll_environment",
      "companies.#{old_demo.id}.shape.company.test_workspace_purpose",
      "companies.#{old_demo.id}.shape.company.migration_rehearsal_status",
      "companies.#{old_demo.id}.shape.company.migration_rehearsal_error_present",
      "companies.#{old_demo.id}.shape.employee_account_links_payroll_environments.#{active_link.id}"
    )
  end

  it "fails closed on empty/malformed/duplicate snapshots, missing fields/links, non-zero history reviews, and tampered data (MEDIUM 1 & 4)" do
    before_snapshot = described_class.capture(
      organization: organization, actor: admin, company_ids: [ old_demo.id ], tax_year: 2026,
      readiness_database_state: -> { shadow_state }
    )
    DemoCompany::ConvertToFlag.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call
    after_snapshot = described_class.capture(
      organization: organization, actor: admin, company_ids: [ old_demo.id ], tax_year: 2026,
      readiness_database_state: -> { shadow_state }
    )

    # Empty hashes must FAIL.
    expect(described_class.diff({}, {})).not_to be_passed

    # Empty companies map must FAIL.
    empty_companies = before_snapshot.merge("companies" => {})
    expect(described_class.diff(empty_companies, empty_companies)).not_to be_passed

    # Same snapshot twice must FAIL by default (both legacy+legacy and converted+converted).
    expect(described_class.diff(before_snapshot, before_snapshot)).not_to be_passed
    expect(described_class.diff(after_snapshot, after_snapshot)).not_to be_passed
    # Explicit retry flag allows converted+converted only.
    expect(described_class.diff(after_snapshot, after_snapshot, expected_company_ids: [ old_demo.id ], allow_already_converted: true)).to be_passed
    expect(described_class.diff(before_snapshot, before_snapshot, expected_company_ids: [ old_demo.id ], allow_already_converted: true)).not_to be_passed

    # Nil company entry must FAIL.
    nil_entry = after_snapshot.deep_dup
    nil_entry["companies"][old_demo.id.to_s] = nil
    expect(described_class.diff(before_snapshot, nil_entry, expected_company_ids: [ old_demo.id ])).not_to be_passed

    # Missing link map entry must FAIL.
    missing_link = after_snapshot.deep_dup
    missing_link["companies"][old_demo.id.to_s]["shape"]["employee_account_links_payroll_environments"] = {}
    expect(described_class.diff(before_snapshot, missing_link, expected_company_ids: [ old_demo.id ])).not_to be_passed

    # Missing required section must FAIL.
    missing_section = after_snapshot.deep_dup
    missing_section["companies"][old_demo.id.to_s].delete("payroll_checksums")
    expect(described_class.diff(before_snapshot, missing_section, expected_company_ids: [ old_demo.id ])).not_to be_passed

    # Mismatched expected_company_ids must FAIL.
    expect(described_class.diff(before_snapshot, after_snapshot, expected_company_ids: [ old_demo.id, 999_999 ])).not_to be_passed

    # Tampered payroll checksum must FAIL.
    tampered = after_snapshot.deep_dup
    tampered["companies"][old_demo.id.to_s]["payroll_checksums"]["payroll_items_sha256"] = "0" * 64
    diff = described_class.diff(before_snapshot, tampered, expected_company_ids: [ old_demo.id ])
    expect(diff).not_to be_passed
    expect(diff.unexpected_diffs.map { |d| d[:path] }).to include("companies.#{old_demo.id}.payroll_checksums.payroll_items_sha256")

    # Missing non-shape key vs explicit null must FAIL, while explicit null on both sides stays equal.
    missing_null_key = after_snapshot.deep_dup
    expect(missing_null_key.dig("companies", old_demo.id.to_s, "employee_app", "readiness")).to be_a(Hash)
    before_with_nil = before_snapshot.deep_dup
    before_with_nil["companies"][old_demo.id.to_s]["employee_app"]["readiness"]["early_access_note"] = nil
    after_with_nil = after_snapshot.deep_dup
    after_with_nil["companies"][old_demo.id.to_s]["employee_app"]["readiness"]["early_access_note"] = nil
    expect(described_class.diff(before_with_nil, after_with_nil, expected_company_ids: [ old_demo.id ])).to be_passed

    diff_missing_key = described_class.diff(before_with_nil, missing_null_key, expected_company_ids: [ old_demo.id ])
    expect(diff_missing_key).not_to be_passed
    expect(diff_missing_key.unexpected_diffs).to include(
      path: "companies.#{old_demo.id}.employee_app.readiness.early_access_note",
      before: nil,
      after: :missing
    )

    # Non-zero time_tracking_history must FAIL even if matching in both before and after (including imports_count).
    %w[sources_count imports_count history_reviews_count verified_history_receipts_count].each do |history_key|
      with_history_before = before_snapshot.deep_dup
      with_history_after = after_snapshot.deep_dup
      [ with_history_before, with_history_after ].each do |snap|
        snap["companies"][old_demo.id.to_s]["payroll_checksums"]["time_tracking_history"][history_key] = 1
      end
      res = described_class.diff(with_history_before, with_history_after, expected_company_ids: [ old_demo.id ])
      expect(res).not_to be_passed
      expect(res.unexpected_diffs.map { |d| d[:path] }).to include(
        "before.companies.#{old_demo.id}.payroll_checksums.time_tracking_history.#{history_key}",
        "after.companies.#{old_demo.id}.payroll_checksums.time_tracking_history.#{history_key}"
      )
    end

    # Hollow/empty sections, missing paid-correction evidence, and imports_count: 1 on both sides must FAIL.
    hollow_before = before_snapshot.deep_dup
    hollow_after = after_snapshot.deep_dup
    [ hollow_before, hollow_after ].each do |snap|
      entry = snap["companies"][old_demo.id.to_s]
      entry["identity"] = {}
      entry["logins"] = []
      entry["employee_app"] = {}
      entry["counters"] = {}
      entry["payroll_checksums"].delete("paid_correction_evidence_counts")
      entry["payroll_checksums"].delete("paid_correction_evidence_sha256")
      entry["payroll_checksums"]["time_tracking_history"]["imports_count"] = 1
    end
    hollow_diff = described_class.diff(hollow_before, hollow_after, expected_company_ids: [ old_demo.id ])
    expect(hollow_diff).not_to be_passed
    hollow_paths = hollow_diff.unexpected_diffs.map { |d| d[:path] }
    expect(hollow_paths).to include(
      "before.companies.#{old_demo.id}.identity.company_id",
      "before.companies.#{old_demo.id}.logins",
      "before.companies.#{old_demo.id}.employee_app.eligible_company",
      "before.companies.#{old_demo.id}.counters.client_caps",
      "before.companies.#{old_demo.id}.payroll_checksums.paid_correction_evidence_sha256",
      "before.companies.#{old_demo.id}.payroll_checksums.paid_correction_evidence_counts",
      "before.companies.#{old_demo.id}.payroll_checksums.time_tracking_history.imports_count"
    )
  end

  describe "rake verification tasks" do
    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?("demo:verify_shape_snapshot")
    end

    def with_env(vars)
      keys = %w[ORGANIZATION_ID ACTOR_ID COMPANY_IDS TAX_YEAR OUTPUT BEFORE AFTER CHECK_EMPLOYEE_SERVICE ALLOW_ALREADY_CONVERTED]
      previous = ENV.to_h.slice(*keys)
      keys.each { |k| ENV.delete(k) }
      vars.each { |k, v| ENV[k] = v }
      yield
    ensure
      keys.each { |k| ENV[k] = previous[k] }
    end

    it "captures before/after JSON files and diffs cleanly under strict RLS raise mode" do
      allow(RlsContextGuard).to receive(:mode).and_return("raise")
      expect(RlsContextGuard.mode).to eq("raise")
      Dir.mktmpdir("demo-shape-verify") do |dir|
        before_path = File.join(dir, "before.json")
        after_path = File.join(dir, "after.json")

        Rake::Task["demo:verify_shape_snapshot"].reenable
        with_env("ACTOR_ID" => admin.id.to_s, "COMPANY_IDS" => old_demo.id.to_s, "TAX_YEAR" => "2026", "OUTPUT" => before_path) do
          expect { RlsSpecContext.strict { Rake::Task["demo:verify_shape_snapshot"].invoke } }
            .to output(/OK    demo:verify_shape_snapshot companies=#{old_demo.id}/).to_stdout
        end

        RlsSpecContext.strict do
          DemoCompany::ConvertToFlag.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call
        end

        Rake::Task["demo:verify_shape_snapshot"].reenable
        with_env("ACTOR_ID" => admin.id.to_s, "COMPANY_IDS" => old_demo.id.to_s, "TAX_YEAR" => "2026", "OUTPUT" => after_path) do
          expect { RlsSpecContext.strict { Rake::Task["demo:verify_shape_snapshot"].invoke } }
            .to output(/OK    demo:verify_shape_snapshot companies=#{old_demo.id}/).to_stdout
        end

        Rake::Task["demo:verify_shape_diff"].reenable
        with_env("COMPANY_IDS" => old_demo.id.to_s, "BEFORE" => before_path, "AFTER" => after_path) do
          expect { RlsSpecContext.strict { Rake::Task["demo:verify_shape_diff"].invoke } }
            .to output(/OK    demo:verify_shape_diff companies=#{old_demo.id} unexpected_diffs=0/).to_stdout
        end
      end
    end
  end
end
