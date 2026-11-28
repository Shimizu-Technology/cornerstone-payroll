# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Readiness override Pub 15-T withholding" do
  include EmployeeLifecyclePr4Helpers

  let(:company) { create(:company, name: "Fictional Payroll Client") }
  let(:actor) { create(:user, company: company, role: "org_admin", name: "Riley Admin", email: "riley@example.test") }
  let(:employee) { create_lifecycle_worker!(company, pay_rate: 25) }
  let(:period) do
    create(:pay_period, company: company, start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
  end

  before do
    unlock_lifecycle_mode!
    create_client_managed_profile!(company)
    allow($stdout).to receive(:puts)
    load Rails.root.join("db/seeds/tax_configs.rb")
  end

  def grant_override
    EmployeeReadinessOverrides::Manage.new(company_id: company.id, employee_id: employee.id, actor: actor,
      verified: true, impersonated: false)
      .grant!(pay_period_id: period.id, default_w4_acknowledged: true, reason: "Verify missing Form W-4 withholding.")
  end

  def receive_w4(**attributes)
    EmployeeW4ElectionChangeService.new(employee: employee.reload, actor: actor, source: "staff",
      reason: "Replace default with the received W-4.", election_received: true,
      attributes: { filing_status: "married", w4_effective_on: period.pay_date }.merge(attributes)).call!
  end

  it "calculates exact Single, no-adjustment withholding and snapshots the append-only election" do
    override = grant_override
    election = override.default_w4_election
    expect(election).to have_attributes(source: "default_withholding", effective_on: employee.hire_date,
      created_by: actor, filing_status: "single", w4_signed_on: nil)
    expect(election.w4_source_reference).to include("##{override.id}", "IRS Pub 15-T")
    expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: employee.reload)).to be_nil
    item = create(:payroll_item, company: company, pay_period: period, employee: employee, pay_rate: 25, hours_worked: 80)

    PayrollCalculator.for(employee, item).calculate
    # 2026 Publication 15-T Worksheet 1A and standard biweekly table for
    # $2,000 of wages, Single, no adjustments.
    expect(item.gross_pay).to eq(2_000)
    expect(item.withholding_tax).to eq(BigDecimal("156.15"))
    expect(item.additional_withholding).to eq(0)
    expect(item.tax_rule_snapshot.dig("withholding_source", "url")).to eq("https://www.irs.gov/publications/p15t")
    expect(item.tax_rule_snapshot.fetch("w4")).to include(
      "election_id" => election.id, "election_source" => "default_withholding", "filing_status_entered" => "single",
      "step2_multiple_jobs" => false, "step3_dependent_credit" => 0, "step4a_other_income" => 0,
      "step4b_deductions" => 0, "step4c_extra_withholding" => 0, "legacy_allowances" => 0
    )

    expect { receive_w4 }.to raise_error(EmployeeW4ElectionChangeService::Error, /signed date or source reference/)
    expect { receive_w4(w4_source_reference: election.w4_source_reference) }
      .to raise_error(EmployeeW4ElectionChangeService::Error, /signed date or source reference/)
    replacement = receive_w4(w4_signed_on: period.pay_date - 1.day, w4_source_reference: nil)
    expect(employee.reload.w4_election_on(period.pay_date)).to eq(replacement)
    expect(replacement).to have_attributes(source: "staff", filing_status: "married")
    expect(election.reload.source).to eq("default_withholding")
    expect(EmployeeReadinessEvaluator.for_pay_period(employee, period)).to be_ready
  end

  it "preserves a future signed W-4 and requires evidence to replace the earlier override default" do
    future_date = period.pay_date + 14.days
    future = receive_w4(w4_effective_on: future_date, w4_signed_on: future_date - 1.day)
    override = grant_override

    expect(employee.reload.w4_election_on(period.pay_date)).to eq(override.default_w4_election)
    expect(employee.w4_election_on(future_date)).to eq(future)
    expect do
      EmployeeW4ElectionChangeService.new(employee: employee, actor: actor, source: "staff",
        reason: "Synthetic backdated update.", attributes: { filing_status: "head_of_household", w4_effective_on: period.pay_date }).call!
    end.to raise_error(EmployeeW4ElectionChangeService::Error, /record receipt/)
    replacement = receive_w4(w4_source_reference: "Signed fixture uploaded to the portal")
    expect(employee.reload.w4_election_on(period.pay_date)).to eq(replacement)
    expect(employee.w4_election_on(future_date)).to eq(future)
  end

  it "shadows a new hire's pre-2020 W-4 with the payroll default until a valid election applies" do
    legacy_date = period.pay_date - 7.days
    legacy = EmployeeW4ElectionChangeService.new(employee: employee, actor: actor, source: "client_direct",
      reason: "Record the synthetic outdated form.", attributes: {
        filing_status: "married", allowances: 3, additional_withholding: 10,
        w4_form_version: 2019, w4_effective_on: legacy_date, w4_signed_on: legacy_date
      }).call!
    future_date = period.pay_date + 14.days
    future = receive_w4(w4_form_version: 2020, w4_effective_on: future_date, w4_signed_on: future_date - 1.day)
    expect(EmployeeReadinessEvaluator.for_pay_period(employee.reload, period).missing_keys).to eq([ "tax_form" ])

    override = grant_override
    default = override.default_w4_election
    expect(default).to have_attributes(source: "default_withholding", effective_on: legacy_date,
      w4_form_version: 2020, filing_status: "single", allowances: 0, additional_withholding: 0, w4_signed_on: nil)
    expect(legacy.reload.w4_form_version).to eq(2019)
    expect(employee.reload.w4_election_on(period.pay_date)).to eq(default)
    expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: employee)).to be_nil
    item = create(:payroll_item, company: company, pay_period: period, employee: employee, pay_rate: 25, hours_worked: 80)
    PayrollCalculator.for(employee, item).calculate
    expect(item.withholding_tax).to eq(BigDecimal("156.15"))

    replacement = receive_w4(w4_form_version: 2020, w4_signed_on: period.pay_date)
    expect(employee.reload.w4_election_on(period.pay_date)).to eq(replacement)
    expect(EmployeeReadinessEvaluator.for_pay_period(employee, period)).to be_ready
    expect(employee.w4_election_on(future_date)).to eq(future)
  end
end
