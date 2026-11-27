# frozen_string_literal: true

require_relative "../parity_helper"

# Run explicitly, on the BASE revision only (not part of the suite: no _spec
# suffix), to regenerate spec/fixtures/files/parity/base_stub_digests.json:
#   BASE_OUT=all.json BASE_OVERLAP_OUT=overlap.json bundle exec rspec spec/parity/tools/base_stub_digests_generator.rb
# then combine them under "fixtures" and "native_run_inside_bridge". Records the digest and
# printed YTD each fixture stub was posted with, as base code posts it.
RSpec.describe "Base stub digests", type: :request do
  include Parity::ParityContext

  def printed(item)
    statement = PayStubGenerator.new(item.reload, employee_copy: true).statement
    {
      "ytd_gross" => statement.dig(:ytd, :gross).to_d.round(2).to_s("F"),
      "ytd_net" => statement.dig(:ytd, :net).to_d.round(2).to_s("F"),
      "taxes" => statement.fetch(:taxes).to_h { |row| [ row[:label], row[:ytd]&.to_d&.round(2)&.to_s("F") ] }
    }
  end

  def post(key)
    TenantScope.as_system(reason: "base digest generator") do
      EmployeeDocuments::PostPayStub.new(fixture.items.fetch(key).reload, now: Parity::FixtureBuilder::POSTING_NOW).call
    end
  end

  it "records every fixture stub" do
    out = {}
    fixture.items.each_key do |key|
      document = post(key)
      next unless document

      out[key.to_s] = { "payroll_facts_sha256" => document.payroll_facts_sha256, "printed" => printed(fixture.items.fetch(key)) }
    end
    File.write(ENV.fetch("BASE_OUT"), JSON.pretty_generate(out))
  end

  context "with a native run inside the bridge window" do
    let(:fixture_scenarios) { [ :prior_provider_ytd ] }

    it "records the later stub" do
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
      document = post(:prior_provider_ytd_p2)
      File.write(ENV.fetch("BASE_OVERLAP_OUT"), JSON.pretty_generate(
        "prior_provider_ytd_p2" => { "payroll_facts_sha256" => document.payroll_facts_sha256, "printed" => printed(fixture.items.fetch(:prior_provider_ytd_p2)) }
      ))
    end
  end
end
