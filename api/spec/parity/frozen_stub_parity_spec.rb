# frozen_string_literal: true

require_relative "parity_helper"

# Production holds employee pay stubs frozen by earlier code. Each one here
# carries the digest the BASE revision posted it with
# (spec/fixtures/files/parity/base_stub_digests.json, from
# spec/parity/tools/base_stub_digests_generator.rb), so a change in what this
# code fingerprints shows up as an unwanted "Corrected" re-post. Stubs whose
# printed figures are unchanged must stay as posted; real changes must revise.
RSpec.describe "Frozen posted pay stubs posted by the base revision", type: :request do
  include Parity::ParityContext

  def base
    @base ||= JSON.parse(Rails.root.join("spec/fixtures/files/parity/base_stub_digests.json").read)
  end

  def printed(item)
    statement = PayStubGenerator.new(item.reload, employee_copy: true).statement
    {
      "ytd_gross" => statement.dig(:ytd, :gross).to_d.round(2).to_s("F"),
      "ytd_net" => statement.dig(:ytd, :net).to_d.round(2).to_s("F"),
      "taxes" => statement.fetch(:taxes).to_h { |row| [ row[:label], row[:ytd]&.to_d&.round(2)&.to_s("F") ] }
    }
  end

  # Replaces this code's digest with the one the base revision stored, and
  # makes the stub due for its recheck, as production stubs will be.
  def as_posted_by_base!(key, digest)
    document = fixture.ensure_stub_posted!(key)
    expect(document).to be_present, "#{key} did not post"
    EmployeeDocument.where(id: document.id).update_all(payroll_facts_sha256: digest, payroll_facts_checked_at: nil)
    document
  end

  def recheck!(key, days: 1)
    TenantScope.as_system(reason: "Parity spec rechecks a posted pay stub") do
      EmployeeDocuments::PostPayStub.new(fixture.items.fetch(key).reload, now: Parity::FixtureBuilder::POSTING_NOW + days.days).call
    end
  end

  it "keeps every stub the base revision posted, printing the same figures" do
    documents = base.fetch("fixtures").to_h do |key, base|
      expect(printed(fixture.items.fetch(key.to_sym))).to eq(base.fetch("printed")), "#{key} prints different YTD from the base revision"
      [ key, as_posted_by_base!(key.to_sym, base.fetch("payroll_facts_sha256")) ]
    end
    expect(documents.size).to eq(25)

    documents.each_key { |key| recheck!(key.to_sym) }

    documents.each do |key, document|
      expect(document.reload).to be_posted, "#{key} was re-posted as Corrected"
      expect(document.revision).to eq(1)
      expect(document.payroll_facts_checked_at).to be_present
      expect(EmployeeDocument.where(payroll_item_id: document.payroll_item_id).count).to eq(1)
    end
  end

  it "revises a base-posted stub when an earlier paycheck really changed" do
    posted = base.dig("fixtures", "hourly_overtime_p2")
    document = as_posted_by_base!(:hourly_overtime_p2, posted.fetch("payroll_facts_sha256"))
    fixture.items.fetch(:hourly_overtime_p1).update_columns(withholding_tax: fixture.items.fetch(:hourly_overtime_p1).withholding_tax + 1)

    revised = recheck!(:hourly_overtime_p2)

    expect(revised.revision).to eq(2)
    expect(document.reload).to be_replaced
    expect(printed(fixture.items.fetch(:hourly_overtime_p2)).dig("taxes", "Guam income tax").to_d)
      .to eq(posted.dig("printed", "taxes", "Guam income tax").to_d + 1)
  end

  context "with a native run inside the bridge window" do
    let(:fixture_scenarios) { [ :prior_provider_ytd ] }

    def overlap_run!
      employee = fixture.employees.fetch(:prior_provider_ytd)
      period = PayPeriod.new(company: fixture.company, status: "approved", start_date: Date.new(2025, 12, 25),
        end_date: Date.new(2026, 1, 7), pay_date: Date.new(2026, 1, 9))
      period.save!(validate: false)
      item = period.payroll_items.build(company: fixture.company, employee: employee, employment_type: "hourly",
        pay_rate: BigDecimal("22.00"), hours_worked: BigDecimal("40.00"), payment_delivery_method: "direct_deposit")
      PayrollCalculator.for(employee, item).calculate
      item.save!
      allow_any_instance_of(PayPeriod).to receive(:starts_after_historical_ytd_boundary)
      TenantScope.with_company(fixture.company.id) { PayPeriodLifecycleService.new(pay_period: period, actor: fixture.staff_user).commit! }
      item.reload
    end

    it "keeps the stub the base revision posted, since an overlap changes no figure" do
      overlap_run!
      posted = base.dig("native_run_inside_bridge", "prior_provider_ytd_p2")
      document = as_posted_by_base!(:prior_provider_ytd_p2, posted.fetch("payroll_facts_sha256"))
      expect(printed(fixture.items.fetch(:prior_provider_ytd_p2))).to eq(posted.fetch("printed"))

      recheck!(:prior_provider_ytd_p2)

      expect(document.reload).to be_posted
      expect(document.revision).to eq(1)
      expect(PayrollBridgeOverlap.new(company_id: fixture.company.id, year: 2026).call.size).to eq(1)
    end
  end
end
