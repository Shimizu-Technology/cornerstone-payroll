# frozen_string_literal: true

require "rails_helper"
require "rake"
require "tmpdir"

RSpec.describe DemoCompany::RenameFixture do
  let!(:tax_tables) { %w[single married].map { |status| create(:tax_table, tax_year: 2026, filing_status: status) } }
  let!(:annual_config) do
    create(:annual_tax_config, tax_year: 2026, ss_wage_base: 184_500, ss_rate: 0.062, medicare_rate: 0.0145,
      additional_medicare_rate: 0.009, additional_medicare_threshold: 200_000, is_active: false).tap do |config|
      %w[single married].each do |status|
        filing = create(:filing_status_config, annual_tax_config: config, filing_status: status, standard_deduction: 0)
        create(:tax_bracket, filing_status_config: filing, bracket_order: 1, min_income: 0, max_income: nil, rate: 0.10)
      end
    end
  end
  let(:organization) { create(:organization, client_limit: 2) }
  let!(:live) do
    create(:company, organization: organization, name: "Live Client", address_line1: "500 Live Office Way",
      bank_address: "501 Live Bank Way, Hagåtña, GU 96910", filing_contact_name: "Live Contact")
  end
  let(:live_employee) do
    create(:employee, company: live, department: create(:department, company: live),
      first_name: "Real", last_name: "Worker", address_line1: "502 Live Worker Way", ssn_encrypted: "900-01-1001")
  end
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin", name: "Org Admin") }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(Resend::Emails).to receive(:send).and_raise("The rename must not send email")
    allow_any_instance_of(ClerkInvitationService).to receive(:create_invitation).and_raise("The rename must not invite anyone")
  end

  after { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }

  def kitchen = Company.demo.find_by!("test_workspace_manifest ->> 'demo_fixture_key' = 'harbor-finch-kitchen'")
  def catering = Company.demo.find_by!("test_workspace_manifest ->> 'demo_fixture_key' = 'harbor-finch-catering'")

  # Seeds a full pre-Track-D demo using legacy names and addresses through the
  # REAL DemoCompany::Seed and DemoCompany::QuickbooksSample pipeline so the
  # retained QuickBooks .xls originals, bundle_digest, HistoricalWorker,
  # HistoricalPaycheck, YTD bridge, and native payroll are all authentic
  # pre-rename artifacts.
  def with_legacy_seeded_demo!
    legacy_people = DemoCompany::Roster::PEOPLE.map do |person|
      person.merge(
        first: "Legacy#{format('%02d', person[:number])}",
        last: "Persona#{format('%02d', person[:number])}"
      )
    end.freeze

    original_people = DemoCompany::Roster::PEOPLE
    DemoCompany::Roster.send(:remove_const, :PEOPLE)
    DemoCompany::Roster.const_set(:PEOPLE, legacy_people)
    begin
      DemoCompany::Seed.new(organization: organization, actor: admin).call
    ensure
      DemoCompany::Roster.send(:remove_const, :PEOPLE)
      DemoCompany::Roster.const_set(:PEOPLE, original_people)
    end

    kitchen.update!(
      address_line1: "999 Legacy Road", bank_address: "888 Legacy Bank Blvd, Hagåtña, GU 96910",
      filing_contact_name: "Legacy Manager"
    )
    catering.update!(
      address_line1: "777 Legacy Highway", bank_address: "888 Legacy Bank Blvd, Hagåtña, GU 96910",
      filing_contact_name: "Legacy Manager"
    )
    kitchen.help_contacts.find_by!(position: 1).update!(name: "Legacy Manager")
    Employee.where(company: [ kitchen, catering ]).order(:id).each_with_index do |employee, index|
      employee.update!(address_line1: "#{100 + index} Legacy Street")
    end
  end

  def create_demo_logins!(manager_email: "reviewer+manager@demo-mail.example",
                          client_email: "reviewer+client@demo-mail.example",
                          emp_email: "reviewer+emp06@demo-mail.example")
    ENV[DemoOutbound::ENV_KEY] = [ manager_email, client_email, emp_email ].join(",")

    manager_user = create(:user, company: kitchen, organization: organization, role: "client",
      email: manager_email, name: "Legacy Manager")
    CompanyAssignment.create!(user: manager_user, company: kitchen)

    client_user = create(:user, company: kitchen, organization: organization, role: "client",
      email: client_email, name: "Legacy Viewer")
    CompanyAssignment.create!(user: client_user, company: kitchen)

    emp06_kitchen = Employee.find_by!(company: kitchen, ssn_encrypted: DemoCompany::Roster.ssn_variants(
      DemoCompany::Roster::PEOPLE.find { |p| p[:key] == "employee-06-kitchen" }
    ))
    emp06_catering = Employee.find_by!(company: catering, ssn_encrypted: DemoCompany::Roster.ssn_variants(
      DemoCompany::Roster::PEOPLE.find { |p| p[:key] == "employee-06-catering" }
    ))
    portal_user = create(:user, company: kitchen, organization: organization, role: "portal_employee",
      email: emp_email, name: "Legacy Dual")
    EmployeeAccountLink.create!(company: kitchen, employee: emp06_kitchen, user: portal_user,
      status: "active", activated_at: Time.current)
    EmployeeAccountLink.create!(company: catering, employee: emp06_catering, user: portal_user,
      status: "active", activated_at: Time.current)

    { manager: manager_user, client: client_user, portal: portal_user }
  end

  around do |example|
    saved = ENV[DemoOutbound::ENV_KEY]
    example.run
  ensure
    ENV[DemoOutbound::ENV_KEY] = saved
  end

  it "renames a demo seeded from legacy QuickBooks originals, audits old-to-new keys, preserves frozen originals, and stays idempotent" do
    live_employee
    with_legacy_seeded_demo!
    logins = create_demo_logins!

    batch = HistoricalImportBatch.find_by!(company: kitchen)
    original_bundle_digest = batch.bundle_digest
    original_source_digests = batch.historical_import_source_files.in_manifest_order.pluck(:original_filename, :sha256)
    old_worker_keys = batch.historical_workers.order(:id).pluck(:external_key)
    old_paycheck_keys = batch.historical_paychecks.order(:id).pluck(:external_key)

    # Confirm the legacy seed genuinely imported the old-roster originals.
    expect(batch.historical_workers.order(:source_name).pluck(:source_name))
      .to eq((1..8).map { |n| format("Persona%02d, Legacy%02d", n, n) })

    # 1. Dry-run reports every planned change and writes nothing.
    dry = described_class.new(organization: organization, actor: admin, dry_run: true).call
    expect(dry.dry_run).to be(true)
    expect(dry.companies.map(&:id)).to contain_exactly(kitchen.id, catering.id)
    expect(dry.unmatched_employee_ids).to be_empty
    expect(dry.counts).to include(
      "company" => 2,
      "company_help_contact" => 1,
      "employee" => 12,
      "historical_worker" => 8,
      "historical_paycheck" => DemoCompany::QuickbooksSample.paychecks.size,
      "user" => 3
    )
    expect(kitchen.reload.address_line1).to eq("999 Legacy Road")
    expect(Employee.where(company: kitchen, first_name: "Employee")).to be_empty
    expect(AuditLog.where(action: "demo_company#fixture_renamed")).to be_empty

    # 2. Apply writes all keyed renames atomically and leaves live data untouched.
    applied = described_class.new(organization: organization, actor: admin, dry_run: false).call
    expect(applied.dry_run).to be(false)
    expect(applied.counts).to eq(dry.counts)

    expect(kitchen.reload).to have_attributes(
      address_line1: "101 Harbor Finch Way", city: "Hagåtña", state: "GU", zip: "96910",
      bank_address: "303 Tasi Cove Plaza, Hagåtña, GU 96910", filing_contact_name: "Client Manager"
    )
    expect(catering.reload).to have_attributes(
      address_line1: "202 Coral Lantern Lane", city: "Maite", state: "GU", zip: "96910",
      bank_address: "303 Tasi Cove Plaza, Hagåtña, GU 96910", filing_contact_name: "Client Manager"
    )
    expect(kitchen.help_contacts.order(:position).pluck(:name)).to eq([ "Client Manager", "Front office" ])

    demo_employees = Employee.where(company: [ kitchen, catering ])
    expect(demo_employees.map(&:full_name).uniq.sort).to eq((1..11).map { |n| format("Employee %02d", n) })
    dual = Employee.where(company: [ kitchen, catering ], first_name: "Employee", last_name: "06")
    expect(dual.count).to eq(2)
    expect(dual.map(&:address_line1).uniq).to eq([ "106 Finch Cove Lane" ])

    batch.reload
    expect(batch.historical_workers.order(:source_name).pluck(:source_name)).to eq((1..8).map { |n| format("%02d, Employee", n) })
    expect(batch.historical_workers.map { |w| w.private_snapshot_data.to_json }.join).not_to include("Legacy", "Persona")
    expect(batch.historical_paychecks.distinct.order(:source_employee_name).pluck(:source_employee_name))
      .to eq((1..8).map { |n| format("%02d, Employee", n) })

    # Retained originals remain immutable evidence; old-to-new key mappings are audited.
    expect(batch.bundle_digest).to eq(original_bundle_digest)
    expect(batch.historical_import_source_files.in_manifest_order.pluck(:original_filename, :sha256)).to eq(original_source_digests)
    kitchen_audit = AuditLog.find_by!(action: "demo_company#fixture_renamed", company_id: kitchen.id)
    mapping = kitchen_audit.metadata.dig("historical_batch_key_mappings", batch.id.to_s)
    expect(mapping["bundle_digest"]).to eq(original_bundle_digest)
    expect(mapping["worker_keys"].keys).to match_array(old_worker_keys)
    expect(mapping["worker_keys"].values).to match_array(batch.historical_workers.pluck(:external_key))
    expect(mapping["paycheck_keys"].keys).to match_array(old_paycheck_keys)
    expect(mapping["paycheck_keys"].values).to match_array(batch.historical_paychecks.pluck(:external_key))

    expect(logins[:manager].reload.name).to eq("Client Manager")
    expect(logins[:client].reload.name).to eq("Client User")
    expect(logins[:portal].reload.name).to eq("Employee 06")

    # Real company and staff user are untouched.
    expect(live.reload).to have_attributes(
      address_line1: "500 Live Office Way", bank_address: "501 Live Bank Way, Hagåtña, GU 96910",
      filing_contact_name: "Live Contact"
    )
    expect(live_employee.reload).to have_attributes(first_name: "Real", last_name: "Worker", address_line1: "502 Live Worker Way")
    expect(admin.reload.name).to eq("Org Admin")

    # 3. QuickBooks sample stub PDFs match 100% of the renamed historical paychecks.
    Dir.mktmpdir("trackd-renamed-stubs") do |dir|
      previews = DemoCompany::QuickbooksSample.new(output_dir: dir).call.stub_pdfs.flat_map do |pdf|
        upload = Rack::Test::UploadedFile.new(pdf, "application/pdf", true, original_filename: File.basename(pdf))
        TenantScope.with_company(kitchen.id) { EmployeeDocuments::ReviewQuickbooksStubs.new(company: kitchen, actor: admin, upload: upload).preview }
      end
      expect(previews.map { |page| page[:status] }).to all(eq("matched"))
      expect(previews.size).to eq(DemoCompany::QuickbooksSample.paychecks.size)
    end

    # 4. Rerunning DemoCompany::Seed after rename is a no-op with zero duplicates.
    seed_rerun = DemoCompany::Seed.new(organization: organization, actor: admin).call
    expect([ seed_rerun.employees_created, seed_rerun.periods_committed, seed_rerun.quickbooks_imported ]).to eq([ 0, 0, false ])
    expect(Employee.where(company: [ kitchen, catering ]).count).to eq(12)

    # 5. Rerunning RenameFixture is completely idempotent.
    second = described_class.new(organization: organization, actor: admin, dry_run: false).call
    expect(second.changes).to be_empty
    expect(AuditLog.where(action: "demo_company#fixture_renamed").count).to eq(2)
  end

  it "refuses any QuickBooks batch that is not locked with an applied YTD bridge" do
    with_legacy_seeded_demo!
    batch = HistoricalImportBatch.find_by!(company: kitchen)

    batch.update_columns(status: "applied")
    expect do
      described_class.new(organization: organization, actor: admin, dry_run: false).call
    end.to raise_error(described_class::Refused, /must be locked with an applied YTD bridge/)
    expect(kitchen.reload.address_line1).to eq("999 Legacy Road")

    batch.update_columns(status: "locked")
    batch.historical_ytd_bridges.update_all(status: "previewed", applied_at: nil, applied_by_id: nil, apply_acknowledgement: nil)
    expect do
      described_class.new(organization: organization, actor: admin, dry_run: false).call
    end.to raise_error(described_class::Refused, /must be locked with an applied YTD bridge/)
    expect(kitchen.reload.address_line1).to eq("999 Legacy Road")
  end

  it "rolls back the entire rename atomically if any step or audit write fails" do
    with_legacy_seeded_demo!
    logins = create_demo_logins!
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid)

    expect do
      described_class.new(organization: organization, actor: admin, dry_run: false).call
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(kitchen.reload.address_line1).to eq("999 Legacy Road")
    expect(catering.reload.address_line1).to eq("777 Legacy Highway")
    expect(Employee.where(company: [ kitchen, catering ], first_name: "Employee")).to be_empty
    expect(logins[:manager].reload.name).to eq("Legacy Manager")
    expect(logins[:portal].reload.name).to eq("Legacy Dual")
  end

  it "refuses ambiguous client logins unless CLIENT_USER_MAP is provided" do
    with_legacy_seeded_demo!
    logins = create_demo_logins!(manager_email: "reviewer+alpha@demo-mail.example", client_email: "reviewer+beta@demo-mail.example")

    expect do
      described_class.new(organization: organization, actor: admin, dry_run: false).call
    end.to raise_error(described_class::Refused, /Ambiguous client manager login/)
    expect(kitchen.reload.address_line1).to eq("999 Legacy Road")

    result = described_class.new(
      organization: organization,
      actor: admin,
      dry_run: false,
      client_user_map: { logins[:manager].id => "Client Manager", logins[:client].id => "Client User" }
    ).call
    expect(result.counts["user"]).to eq(3)
    expect(logins[:manager].reload.name).to eq("Client Manager")
    expect(logins[:client].reload.name).to eq("Client User")
  end

  it "reports unmatched custom employees without modifying them and honors explicit employee_map" do
    with_legacy_seeded_demo!
    extra = create(:employee, company: catering, department: catering.departments.first,
      first_name: "Custom", last_name: "Tester", ssn_encrypted: "900-01-9999", address_line1: "42 Custom Lane")

    result = described_class.new(organization: organization, actor: admin, dry_run: false).call
    expect(result.unmatched_employee_ids).to eq([ extra.id ])
    expect(extra.reload).to have_attributes(first_name: "Custom", last_name: "Tester", address_line1: "42 Custom Lane")

    mapped = described_class.new(organization: organization, actor: admin, dry_run: false,
      company_ids: [ catering.id ], employee_map: { extra.id => "employee-11" }).call
    expect(mapped.unmatched_employee_ids).to be_empty
    expect(extra.reload).to have_attributes(first_name: "Employee", last_name: "11", address_line1: "111 Finch Cove Lane")
  end

  it "refuses non-demo company_ids and non-admin actors" do
    with_legacy_seeded_demo!
    expect do
      described_class.new(organization: organization, actor: admin, dry_run: false, company_ids: [ live.id ]).call
    end.to raise_error(described_class::Refused, /not a demo company/)

    accountant = create(:user, company: live, organization: organization, role: "accountant")
    expect do
      described_class.new(organization: organization, actor: accountant, dry_run: false).call
    end.to raise_error(described_class::Refused, /administrator/)
  end

  describe "rake demo:rename_fixture", :rls do
    let(:task) { Rake::Task["demo:rename_fixture"] }

    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?("demo:rename_fixture")
      task.reenable
    end

    def run_task(apply: nil, company_ids: nil, employee_map: nil, client_user_map: nil)
      saved = ENV.to_h.slice("ORGANIZATION_ID", "ACTOR_ID", "APPLY", "COMPANY_IDS", "EMPLOYEE_MAP", "CLIENT_USER_MAP")
      ENV["ORGANIZATION_ID"] = organization.id.to_s
      ENV["ACTOR_ID"] = admin.id.to_s
      ENV["APPLY"] = apply
      ENV["COMPANY_IDS"] = company_ids
      ENV["EMPLOYEE_MAP"] = employee_map
      ENV["CLIENT_USER_MAP"] = client_user_map
      task.reenable
      task.invoke
    ensure
      %w[ORGANIZATION_ID ACTOR_ID APPLY COMPANY_IDS EMPLOYEE_MAP CLIENT_USER_MAP].each { |key| ENV[key] = saved[key] }
    end

    it "prints dry-run field plans without values and applies with maps under RLS raise mode when APPLY=true" do
      logins = nil
      extra = nil
      kitchen_id = nil
      TenantScope.as_system(reason: "Seed legacy demo for rake spec") do
        with_legacy_seeded_demo!
        kitchen_id = kitchen.id
        logins = create_demo_logins!(manager_email: "reviewer+alpha@demo-mail.example", client_email: "reviewer+beta@demo-mail.example")
        extra = create(:employee, company: catering, department: catering.departments.first,
          first_name: "Custom", last_name: "Tester", ssn_encrypted: "900-01-9999", address_line1: "42 Custom Lane")
      end
      expect(RlsContextGuard.mode).to eq("raise")

      user_map_env = "#{logins[:manager].id}=Client Manager,#{logins[:client].id}=Client User"
      emp_map_env = "#{extra.id}=employee-11"

      output = capture_stdout { run_task(employee_map: emp_map_env, client_user_map: user_map_env) }
      expect(output).to match(/PLAN  company id=#{kitchen_id} fields=address_line1,bank_address,filing_contact_name/)
      expect(output).to match(/PLAN  employee id=#{extra.id} fields=address_line1,city,first_name,last_name/)
      expect(output).to match(/OK    demo:rename_fixture mode=dry_run .*changes=\d+/)
      expect(output).not_to include("Legacy", "Harbor Finch Way", "Client Manager", "reviewer+")

      TenantScope.as_system(reason: "Check dry_run left legacy address") do
        expect(kitchen.address_line1).to eq("999 Legacy Road")
      end

      expect { run_task(apply: "true", employee_map: emp_map_env, client_user_map: user_map_env) }
        .to output(/OK    demo:rename_fixture mode=applied .*changes=\d+/).to_stdout
      TenantScope.as_system(reason: "Check applied state") do
        expect(kitchen.address_line1).to eq("101 Harbor Finch Way")
        expect(extra.reload.full_name).to eq("Employee 11")
        expect(logins[:manager].reload.name).to eq("Client Manager")
      end

      expect { run_task(apply: "true", employee_map: emp_map_env, client_user_map: user_map_env) }
        .to output(/OK    demo:rename_fixture mode=applied .*changes=0 unmatched_employees=0 none/).to_stdout
    end

    def capture_stdout
      buffer = StringIO.new
      previous = $stdout
      $stdout = buffer
      yield
      buffer.string
    ensure
      $stdout = previous
    end
  end
end
