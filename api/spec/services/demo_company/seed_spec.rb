# frozen_string_literal: true

require "rails_helper"

RSpec.describe DemoCompany::Seed do
  let!(:tax_tables) { %w[single married].map { |status| create(:tax_table, tax_year: 2026, filing_status: status) } }
  let(:organization) { create(:organization, client_limit: 2) }
  let!(:live) { create(:company, organization: organization, name: "Live Client") }
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin") }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(Resend::Emails).to receive(:send).and_raise("The seed must not send email")
    allow_any_instance_of(ClerkInvitationService).to receive(:create_invitation).and_raise("The seed must not invite anyone")
  end

  def seed!
    described_class.new(organization: organization, actor: admin).call
  end

  def kitchen = Company.demo.find_by!("test_workspace_manifest ->> 'demo_fixture_key' = 'harbor-finch-kitchen'")
  def catering = Company.demo.find_by!("test_workspace_manifest ->> 'demo_fixture_key' = 'harbor-finch-catering'")

  def person(company, first, last)
    Employee.find_by!(company: company, first_name: first, last_name: last)
  end

  def outside_records
    {
      liability_postings: PayrollLiabilityPosting.count, liability_entries: PayrollLiabilityEntry.count,
      filing_records: PayrollFilingRecord.count, filing_events: PayrollFilingEvent.count,
      fit_checks: NonEmployeeCheck.count, aire_batches: AirePayrollAcknowledgement.count,
      aire_entries: AirePayrollEntryAcknowledgement.count, time_sources: TimeTrackingSource.count,
      tax_imports: WorkHourImport.count, invoices: Invoice.count, users: User.count,
      notifications_sent: PortalNotificationDelivery.where(status: "sent").count
    }
  end

  describe "a first run" do
    let!(:before) { outside_records }
    let!(:result) { seed! }

    it "creates both employers as demo companies that look like ordinary clients" do
      expect(result.companies.map(&:name)).to eq([ "Harbor Finch Kitchen", "Harbor Finch Catering" ])
      expect(result.companies).to all(be_demo)
      expect(kitchen).to have_attributes(subdomain_slug: "harborfinch", city: "Hagåtña", check_stock_type: "top_check", auto_create_fit_check: false)
      expect(catering.subdomain_slug).to eq("harborfinch-catering")
      expect(kitchen.branding).to include("display_name" => "Harbor Finch Kitchen")
      expect(kitchen.help_contacts.map(&:name)).to eq([ "Maren Fable", "Front office" ])
      expect(organization.companies.live_payroll.count).to eq(1)
      expect([ kitchen.name, catering.name, kitchen.branding.to_json, kitchen.help_contacts.to_json ].join).not_to match(/demo/i)
    end

    it "creates fictional people with unissued SSNs and fictional bank details" do
      expect(kitchen.employees.count).to eq(10)
      expect(catering.employees.count).to eq(2)
      expect(Employee.where(company: [ kitchen, catering ]).map(&:ssn_digits)).to all(start_with("900"))
      kit = [ person(kitchen, "Kit", "Wren"), person(catering, "Kit", "Wren") ]
      expect(kit.map(&:ssn_digits).uniq.size).to eq(1)
      routing = Employee.where(company: kitchen, payment_delivery_method: "direct_deposit").map(&:bank_routing_number_encrypted)
      expect(routing).to all(be_present)
      expect(routing.map { |number| AbaRoutingNumber.valid_checksum?(number) }).to all(be(false))
      expect(person(kitchen, "Ellis", "Quill").employment_type).to eq("salary")
      expect(person(kitchen, "Jules", "Reed").status).to eq("terminated")
      quinn = person(kitchen, "Quinn", "Sable")
      expect(quinn.status).to eq("active")
      expect(quinn.employee_status_events.order(:effective_date).pluck(:event_type)).to eq(%w[terminated reactivated])
      expect(Employee.where(company: [ kitchen, catering ]).pluck(:email).compact).to be_empty
    end

    it "commits seven biweekly periods per employer through the real calculator and leaves one open" do
      expect(result.periods_committed).to eq(14)
      [ kitchen, catering ].each do |company|
        periods = company.pay_periods.order(:start_date)
        expect(periods.map(&:status)).to eq(Array.new(7, "committed") + [ "draft" ])
        expect(periods.first.start_date).to eq(Date.new(2026, 8, 2))
        expect(periods.map(&:parallel_run)).to all(be(false))
      end
      items = PayrollItem.where(company: kitchen)
      expect(items.map(&:gross_pay)).to all(be_positive)
      expect(items.map(&:net_pay)).to all(be_positive)
      expect(items.sum(:social_security_tax)).to be_positive

      robin = person(kitchen, "Robin", "Lantern").payroll_items.joins(:pay_period).order("pay_periods.start_date").to_a
      expect(robin[1].gross_pay).to be > robin[0].gross_pay
      rowan = person(kitchen, "Rowan", "Drift").payroll_items.joins(:pay_period).order("pay_periods.start_date").first
      expect(rowan.tips).to eq(410.25)
      expect(person(kitchen, "Jules", "Reed").payroll_items.count).to eq(4)
      quinn_periods = person(kitchen, "Quinn", "Sable").payroll_items.joins(:pay_period).pluck("pay_periods.start_date")
      expect(quinn_periods).to contain_exactly(*(described_class.periods.values_at(0, 1, 4, 5, 6).map { |period| period[:start_date] }))
      expect(PayrollItem.where(company: kitchen, payment_delivery_method: "paper_check").pluck(:check_number)).to all(be_present)
      expect(PayrollItem.where(company: kitchen, payment_delivery_method: "direct_deposit").pluck(:check_number)).to all(be_nil)
      expect(EmployeeYtdTotal.where(employee: person(kitchen, "Ellis", "Quill"), year: 2026).sum(:gross_pay)).to be_positive
    end

    it "creates no liability, filing, FIT, AIRE, Tax, invoice, login or email records" do
      expect(outside_records).to eq(before)
    end

    it "leaves the employee app off" do
      [ kitchen, catering ].each do |company|
        features = CompanyFeatures.for(company)
        expect(features.employee_portal_enabled?).to be(false)
        expect(features.subdomain_enabled?).to be(false)
      end
    end

    it "is a no-op the second time" do
      counts = -> { [ Company.demo.count, Employee.count, PayPeriod.count, PayrollItem.count, CompanyHelpContact.count, AuditLog.count ] }
      first = counts.call
      again = seed!
      expect(again.periods_committed).to eq(0)
      expect(again.periods_skipped).to eq(14)
      expect(again.employees_created).to eq(0)
      expect(counts.call).to eq(first)
    end
  end

  it "resumes after an interruption without duplicating payroll" do
    calls = 0
    allow_any_instance_of(PayPeriodLifecycleService).to receive(:commit!).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      raise "Interrupted" if calls == 3

      original.call(*args, **kwargs)
    end
    expect { seed! }.to raise_error("Interrupted")
    expect(kitchen.pay_periods.where(status: "committed").count).to eq(2)
    expect(PayrollItem.joins(:pay_period).where(company: kitchen).where.not(pay_periods: { status: "committed" })).to be_empty

    allow_any_instance_of(PayPeriodLifecycleService).to receive(:commit!).and_call_original
    result = seed!
    expect(result.periods_committed).to eq(12)
    expect(kitchen.pay_periods.where(status: "committed").count).to eq(7)
    expect(PayrollItem.where(company: kitchen).group(:pay_period_id, :employee_id).count.values).to all(eq(1))
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

  it "leaves a live client's commit unchanged: it still posts liabilities" do
    seed!
    employee = create(:employee, company: live, department: create(:department, company: live))
    period = create(:pay_period, company: live, start_date: Date.new(2026, 8, 2), end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 21))
    item = create(:payroll_item, employee: employee, company: live, pay_period: period, hours_worked: 80)
    item.calculate!
    period.update!(status: "approved")
    PayPeriodLifecycleService.new(pay_period: period, actor: admin).commit!

    expect(PayrollLiabilityPosting.where(company: live, pay_period: period)).to exist
    expect(PayrollLiabilityPosting.where(company: [ kitchen, catering ])).to be_empty
  end
end
