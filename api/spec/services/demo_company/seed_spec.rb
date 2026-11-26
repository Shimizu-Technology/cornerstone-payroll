# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe DemoCompany::Seed do
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
  let!(:live) { create(:company, organization: organization, name: "Live Client") }
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin") }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(Resend::Emails).to receive(:send).and_raise("The seed must not send email")
    allow_any_instance_of(ClerkInvitationService).to receive(:create_invitation).and_raise("The seed must not invite anyone")
  end

  after { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }

  def seed! = described_class.new(organization: organization, actor: admin).call
  def kitchen = Company.demo.find_by!("test_workspace_manifest ->> 'demo_fixture_key' = 'harbor-finch-kitchen'")
  def catering = Company.demo.find_by!("test_workspace_manifest ->> 'demo_fixture_key' = 'harbor-finch-catering'")
  def person(company, first, last) = Employee.find_by!(company: company, first_name: first, last_name: last)
  def items_for(employee) = employee.payroll_items.joins(:pay_period).order("pay_periods.start_date").to_a

  def outside_records
    {
      liability_postings: PayrollLiabilityPosting.count, liability_entries: PayrollLiabilityEntry.count,
      filing_records: PayrollFilingRecord.count, filing_events: PayrollFilingEvent.count, non_employee_checks: NonEmployeeCheck.count,
      aire_batches: AirePayrollAcknowledgement.count, aire_entries: AirePayrollEntryAcknowledgement.count,
      time_sources: TimeTrackingSource.count, tax_imports: WorkHourImport.count, invoices: Invoice.count, users: User.count,
      notifications_sent: PortalNotificationDelivery.where(status: "sent").count
    }
  end

  def snapshot
    [ Company.demo.count, Employee.count, PayPeriod.count, PayrollItem.count, HistoricalImportBatch.count, HistoricalPaycheck.count,
      HistoricalYtdBridge.count, HistoricalEmployeeYtdBalance.count, EmployeeYtdTotal.count, CompanyHelpContact.count ]
  end

  it "builds the Kitchen from locked QuickBooks history, then native payroll, like a migrated client" do
    before = outside_records
    result = seed!

    expect(result.companies.map(&:name)).to eq([ "Harbor Finch Kitchen", "Harbor Finch Catering" ])
    expect(result.companies).to all(be_demo)
    expect(kitchen).to have_attributes(subdomain_slug: "harborfinch", check_stock_type: "top_check", auto_create_fit_check: false)
    expect(catering.subdomain_slug).to eq("harborfinch-catering")
    expect(kitchen.help_contacts.map(&:name)).to eq([ "Maren Fable", "Front office" ])
    expect(organization.companies.live_payroll.count).to eq(1)
    expect([ kitchen.name, catering.name, kitchen.branding.to_json, kitchen.help_contacts.to_json ].join).not_to match(/demo/i)

    # QuickBooks first: imported, prepared, verified, reviewed, locked and bridged.
    batch = HistoricalImportBatch.find_by!(company: kitchen)
    expect(batch).to be_locked
    expect(batch.source_system).to eq("quickbooks_online")
    expect(batch.historical_paychecks.count).to eq(DemoCompany::QuickbooksSample.paychecks.size)
    expect(batch.historical_ytd_bridges.pluck(:status)).to eq([ "applied" ])
    expect(HistoricalImportBatch.where(company: catering)).to be_empty
    history = EmployeeDocuments::QuickbooksHistory.scope(kitchen.id)
    expect(history.count).to eq(DemoCompany::QuickbooksSample.paychecks.size)
    expect(history.maximum(:pay_date)).to eq(Date.new(2026, 7, 24))

    # Every person can activate or claim: a birth date and a phone.
    seeded = Employee.where(company: [ kitchen, catering ])
    expect(seeded.count).to eq(DemoCompany::Roster::PEOPLE.size)
    expect(seeded.map(&:date_of_birth)).to all(be_present)
    expect(seeded.map(&:phone)).to all(be_present)
    expect(seeded.map(&:ssn_digits)).to all(start_with("900"))
    expect(seeded.pluck(:email).compact).to be_empty
    expect(seeded.where(employment_type: "contractor")).to be_empty
    expect(seeded.map(&:configuration_review_status)).to all(eq("complete"))
    routing = seeded.where(payment_delivery_method: "direct_deposit").map(&:bank_routing_number_encrypted)
    expect(routing).to all(be_present)
    expect(routing.map { |number| AbaRoutingNumber.valid_checksum?(number) }).to all(be(false))
    expect([ person(kitchen, "Kit", "Wren"), person(catering, "Kit", "Wren") ].map(&:ssn_digits).uniq.size).to eq(1)
    expect(person(kitchen, "Jules", "Reed").status).to eq("terminated")
    expect(person(kitchen, "Quinn", "Sable").employee_status_events.order(:effective_date).pluck(:event_type)).to eq(%w[terminated reactivated])

    # Native payroll from the August 7 payday, through the real calculator.
    expect(result.periods_committed).to eq(16)
    [ kitchen, catering ].each do |company|
      periods = company.pay_periods.order(:start_date)
      expect(periods.map(&:status)).to eq(Array.new(8, "committed") + [ "draft" ])
      expect(periods.first.pay_date).to eq(Date.new(2026, 8, 7))
      expect(periods.map(&:parallel_run)).to all(be(false))
    end
    items = PayrollItem.where(company: kitchen)
    expect(items.map(&:gross_pay)).to all(be_positive)
    expect(items.map(&:net_pay)).to all(be_positive)
    robin = items_for(person(kitchen, "Robin", "Lantern"))
    expect(robin[1].gross_pay).to be > robin[0].gross_pay
    rowan = items_for(person(kitchen, "Rowan", "Drift"))
    expect(rowan.first.tips).to eq(410.25)
    expect(rowan.first.payroll_item_field_entries.sum(:amount)).to eq(15)
    avery = items_for(person(kitchen, "Avery", "Sprig"))
    expect(avery[2].hours_worked).to eq(12)
    drew = items_for(person(kitchen, "Drew", "Flint"))
    expect(drew[3].pay_rate).to eq(15)
    expect(drew[4].pay_rate).to eq(16.25)
    expect(items_for(person(kitchen, "Jules", "Reed")).size).to eq(4)
    expect(PayrollItem.where(company: kitchen, payment_delivery_method: "direct_deposit").pluck(:check_number)).to all(be_nil)
    expect(PayrollItem.where(company: kitchen, payment_delivery_method: "paper_check").pluck(:check_number)).to all(be_present)

    # The bridge and native payroll each count once in the year's wages.
    quickbooks_gross = DemoCompany::QuickbooksSample.paychecks.select { |p| p[:person][:key] == "robin-lantern" }.sum { |p| p[:gross] }
    native_wages = robin.sum(&:fit_taxable_wages)
    w2 = W2GuAggregator.new(kitchen, 2026).generate
    row = w2.fetch(:employees).find { |entry| entry[:employee_id] == person(kitchen, "Robin", "Lantern").id }
    expect(row[:box1_wages_tips_other_comp].to_d).to eq((quickbooks_gross + native_wages).to_d.round(2))

    # Nothing left the building, and the employee app stays off.
    expect(outside_records).to eq(before)
    [ kitchen, catering ].each do |company|
      features = CompanyFeatures.for(company)
      expect(features.employee_portal_enabled?).to be(false)
      expect(features.subdomain_enabled?).to be(false)
    end
  end

  it "matches the generated QuickBooks stub pages to the locked history" do
    seed!
    Dir.mktmpdir("hfk-stubs") do |dir|
      previews = DemoCompany::QuickbooksSample.new(output_dir: dir).call.stub_pdfs.flat_map do |pdf|
        upload = Rack::Test::UploadedFile.new(pdf, "application/pdf", true, original_filename: File.basename(pdf))
        TenantScope.with_company(kitchen.id) { EmployeeDocuments::ReviewQuickbooksStubs.new(company: kitchen, actor: admin, upload: upload).preview }
      end
      expect(previews.map { |page| page[:status] }).to all(eq("matched"))
      expect(previews.size).to eq(DemoCompany::QuickbooksSample.paychecks.size)
    end
  end

  it "is a no-op the second time and after an interruption resumes without duplicating anything" do
    calls = 0
    allow_any_instance_of(PayPeriodLifecycleService).to receive(:commit!).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      raise "Interrupted" if calls == 3

      original.call(*args, **kwargs)
    end
    expect { seed! }.to raise_error("Interrupted")
    expect(kitchen.pay_periods.where(status: "committed").count).to eq(2)
    expect(HistoricalImportBatch.find_by!(company: kitchen)).to be_locked

    allow_any_instance_of(PayPeriodLifecycleService).to receive(:commit!).and_call_original
    expect(seed!.periods_committed).to eq(14)
    first = snapshot
    again = seed!
    expect([ again.periods_committed, again.employees_created, again.quickbooks_imported ]).to eq([ 0, 0, false ])
    expect(snapshot).to eq(first)
    expect(PayrollItem.where(company: kitchen).group(:pay_period_id, :employee_id).count.values).to all(eq(1))
  end

  it "never reseeds a voided window" do
    seed!
    period = kitchen.pay_periods.order(:start_date).second
    # A real void here first needs the direct deposits verified outside the
    # app; the window rule only depends on the voided state.
    period.update_columns(correction_status: "voided", voided_at: Time.current, void_reason: "Entered the wrong week")
    first = snapshot

    result = seed!
    expect(result.periods_committed).to eq(0)
    expect(snapshot).to eq(first)
    expect(kitchen.pay_periods.where(start_date: period.start_date).count).to eq(1)
  end

  it "never commits a draft that sits beside a committed period in the same window" do
    seed!
    committed = kitchen.pay_periods.order(:start_date).first
    stray = PayPeriod.new(committed.attributes.slice("company_id", "company_pay_schedule_id", "company_workweek_id", "start_date", "end_date",
      "pay_date", "run_purpose", "run_purpose_source", "includes_base_salary").merge("status" => "draft"))
    stray.save!(validate: false)

    expect(seed!.periods_committed).to eq(0)
    expect(stray.reload.status).to eq("draft")
    expect(stray.payroll_items).to be_empty
  end

  it "saves a native employee and its initial W-4 election together, and repairs a missing election on rerun" do
    calls = 0
    allow_any_instance_of(EmployeeW4ElectionChangeService).to receive(:call!).and_wrap_original do |original, *args|
      calls += 1
      raise "Election write failed" if calls == 1

      original.call(*args)
    end
    expect { seed! }.to raise_error("Election write failed")
    expect(Employee.where(first_name: "Ellis", last_name: "Quill")).to be_empty

    allow_any_instance_of(EmployeeW4ElectionChangeService).to receive(:call!).and_call_original
    seed!
    ellis = person(kitchen, "Ellis", "Quill")
    expect(ellis.employee_w4_elections.count).to eq(1)

    # A record left without its election (an older partial run) is repaired.
    maren = person(kitchen, "Maren", "Fable")
    EmployeeW4Election.where(employee_id: maren.id).delete_all
    seed!
    expect(maren.reload.employee_w4_elections.count).to eq(1)
  end

  it "refuses a concurrent run for the same organization and releases its lock after an error" do
    key = described_class::LOCK_KEY_BASE + organization.id
    # A separate database session, as a second seed process would have.
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    holder = PG.connect({ host: config[:host], port: config[:port], dbname: config[:database],
                          user: config[:username], password: config[:password] }.compact)
    holder.exec("SELECT pg_advisory_lock(#{key})")
    expect { seed! }.to raise_error(described_class::Refused, /in progress/)
    expect(Company.demo).to be_empty
    holder.exec("SELECT pg_advisory_unlock(#{key})")

    allow_any_instance_of(described_class).to receive(:seed_quickbooks_history!).and_raise("Storage unavailable")
    expect { seed! }.to raise_error("Storage unavailable")
    expect(holder.exec("SELECT pg_try_advisory_lock(#{key}) AS locked").first["locked"]).to eq("t")
  ensure
    holder&.exec("SELECT pg_advisory_unlock_all()")
    holder&.close
  end

  it "keeps a tester's later termination when reseeding" do
    seed!
    quinn = person(kitchen, "Quinn", "Sable")
    open_period = kitchen.pay_periods.find_by!(status: "draft")
    EmployeeStatusTransitionService.terminate!(employee: quinn, actor: admin, attributes: {
      effective_date: open_period.start_date - 1, reason_category: "voluntary", source: "operator"
    })
    expect { seed! }.not_to raise_error
    expect(quinn.reload.status).to eq("terminated")
    expect(quinn.employee_status_events.where(event_type: "reactivated").count).to eq(1)
  end

  it "uses the company a concurrent run created first" do
    original = DemoCompany::Create.instance_method(:call)
    allow_any_instance_of(DemoCompany::Create).to receive(:call) do |create|
      original.bind_call(create)
      raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint"
    end
    result = seed!
    expect(result.companies.map(&:id).uniq.size).to eq(2)
    expect(Company.demo.count).to eq(2)
  end

  it "refuses a live company carrying a demo fixture key and a slug held by a live client" do
    live.update_columns(test_workspace_manifest: { "demo_fixture_key" => "harbor-finch-kitchen" })
    expect { seed! }.to raise_error(described_class::Refused, /not a demo company/)
    expect(live.reload.employees).to be_empty

    live.update_columns(test_workspace_manifest: {}, subdomain_slug: "harborfinch")
    expect { seed! }.to raise_error(described_class::Refused, /belongs to another company/)
    expect(Company.demo).to be_empty
  end

  it "requires an organization administrator" do
    accountant = create(:user, company: live, organization: organization, role: "accountant")
    expect { described_class.new(organization: organization, actor: accountant).call }.to raise_error(described_class::Refused)
  end

  it "leaves a live client's commit unchanged, lifts demo contractor checks, and still refuses demo time-tracking sources" do
    legacy_demo = create_demo_company(organization: organization, fixture_key: "other-demo")
    live_demo = create_live_demo_company(organization: organization, fixture_key: "live-flag-demo")

    expect(build(:employee, company: legacy_demo, department: create(:department, company: legacy_demo), employment_type: "contractor")).to be_valid
    expect(build(:employee, company: live_demo, department: create(:department, company: live_demo), employment_type: "contractor")).to be_valid
    # Legacy demos stay guarded on non_employee_checks until the Track B Migrate phase drops the legacy trigger;
    # new-shape live+demo companies can issue non-employee checks like live clients.
    legacy_check = build(:non_employee_check, company: legacy_demo)
    expect(legacy_check).not_to be_valid
    expect(legacy_check.errors[:base]).to include(Company::DEMO_UNAVAILABLE_MESSAGE)
    expect(build(:non_employee_check, company: live_demo)).to be_valid
    expect(build(:time_tracking_source, company: legacy_demo)).not_to be_valid
    expect(build(:time_tracking_source, company: live_demo)).not_to be_valid

    employee = create(:employee, company: live, department: create(:department, company: live))
    period = create(:pay_period, company: live, start_date: Date.new(2026, 8, 2), end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 21))
    create(:payroll_item, employee: employee, company: live, pay_period: period, hours_worked: 80).calculate!
    period.update!(status: "approved")
    PayPeriodLifecycleService.new(pay_period: period, actor: admin).commit!
    expect(PayrollLiabilityPosting.where(company: live, pay_period: period)).to exist
  end
end
