# frozen_string_literal: true

require "rails_helper"
require "rake"
require "tmpdir"

RSpec.describe DemoCompany::VerifyShapeMigration do
  let!(:organization) { create(:organization, client_limit: 5) }
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
      migration_rehearsal_created_at: 2.days.ago,
      migration_rehearsal_completed_at: 2.days.ago
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

    # Turn on demo employee app & subdomain.
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

    # Inbox activity for the demo (must appear as row but never inflate live summary counters).
    thread = create(:client_portal_thread, company: old_demo, created_by: demo_client_user)
    create(:client_portal_message, company: old_demo, client_portal_thread: thread, author: demo_client_user)

    # Finance book + live invoice so revenue exclusion is exercised.
    book = organization.finance_books.first
    live_invoice = create(:invoice, organization: organization, finance_book: book, company: live, status: "draft", invoice_date: Date.new(2026, 3, 15))
    live_invoice.line_items.create!(item_name: "Payroll Fee", description: "Monthly", quantity: 1, rate: 500, line_kind: "service_fee", position: 1)
    live_invoice.update_columns(status: "open", total_amount: 500)

    # Committed payroll + YTD + posted pay stub document.
    period = create_committed_demo_pay_period(company: old_demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee)
    period.update_columns(committed_at: 2.days.ago)
    item = period.payroll_items.sole
    item.update_columns(payment_delivery_method: "direct_deposit")
    EmployeeYtdTotal.create!(employee: demo_employee, year: 2026, gross_pay: 2_000, net_pay: 1_600)
    CompanyYtdTotal.create!(company: old_demo, year: 2026, gross_pay: 2_000, net_pay: 1_600)
    EmployeeDocuments::PostPayStub.new(item, now: Time.current).call
  end

  it "captures all verification areas read-only and reports zero unexpected diffs after ConvertToFlag" do
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

    entry = before_snapshot.fetch("companies").fetch(old_demo.id.to_s)
    expect(entry.dig("shape", "company", "demo")).to be(false)
    expect(entry.dig("shape", "company", "payroll_environment")).to eq("migration_rehearsal")
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

    # Convert the company.
    DemoCompany::ConvertToFlag.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call

    after_snapshot = described_class.capture(
      organization: organization,
      actor: admin,
      company_ids: [ old_demo.id ],
      tax_year: 2026,
      readiness_database_state: -> { shadow_state }
    )

    diff = described_class.diff(before_snapshot, after_snapshot)
    expect(diff.unexpected_diffs).to eq([])
    expect(diff).to be_passed

    changed_paths = diff.shape_changes.fetch(old_demo.id.to_s).map { |change| change[:path] }
    expect(changed_paths).to include(
      "companies.#{old_demo.id}.shape.company.demo",
      "companies.#{old_demo.id}.shape.company.payroll_environment",
      "companies.#{old_demo.id}.shape.company.test_workspace_purpose",
      "companies.#{old_demo.id}.shape.company.migration_rehearsal_status",
      "companies.#{old_demo.id}.shape.employee_account_links_payroll_environments.#{active_link.id}"
    )
  end

  it "fails the diff if any non-shape field or payroll figure changes or if the after shape is incomplete" do
    before_snapshot = described_class.capture(
      organization: organization, actor: admin, company_ids: [ old_demo.id ], tax_year: 2026,
      readiness_database_state: -> { shadow_state }
    )
    DemoCompany::ConvertToFlag.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call
    after_snapshot = described_class.capture(
      organization: organization, actor: admin, company_ids: [ old_demo.id ], tax_year: 2026,
      readiness_database_state: -> { shadow_state }
    )

    # Tamper a payroll checksum in after_snapshot -> must fail closed.
    tampered = after_snapshot.deep_dup
    tampered["companies"][old_demo.id.to_s]["payroll_checksums"]["payroll_items_sha256"] = "0" * 64
    diff = described_class.diff(before_snapshot, tampered)
    expect(diff).not_to be_passed
    expect(diff.unexpected_diffs.map { |d| d[:path] }).to include("companies.#{old_demo.id}.payroll_checksums.payroll_items_sha256")

    # Unconverted after snapshot -> must fail closed on shape validation.
    unconverted_diff = described_class.diff(before_snapshot, before_snapshot)
    expect(unconverted_diff).not_to be_passed
    expect(unconverted_diff.unexpected_diffs.map { |d| d[:path] }).to include("companies.#{old_demo.id}.shape.company.demo")
  end

  describe "rake verification tasks" do
    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?("demo:verify_shape_snapshot")
    end

    def with_env(vars)
      keys = %w[ORGANIZATION_ID ACTOR_ID COMPANY_IDS TAX_YEAR OUTPUT BEFORE AFTER CHECK_EMPLOYEE_SERVICE]
      previous = ENV.to_h.slice(*keys)
      keys.each { |k| ENV.delete(k) }
      vars.each { |k, v| ENV[k] = v }
      yield
    ensure
      keys.each { |k| ENV[k] = previous[k] }
    end

    it "captures before/after JSON files and diffs cleanly under RLS raise mode" do
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
        with_env("BEFORE" => before_path, "AFTER" => after_path) do
          expect { RlsSpecContext.strict { Rake::Task["demo:verify_shape_diff"].invoke } }
            .to output(/OK    demo:verify_shape_diff companies=#{old_demo.id} unexpected_diffs=0/).to_stdout
        end
      end
    end
  end
end
