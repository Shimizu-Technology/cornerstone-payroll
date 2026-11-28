# frozen_string_literal: true

require "rails_helper"

RSpec.describe "DemoCompany::Seed client-managed lifecycle showcase" do
  include EmployeeLifecyclePr4Helpers

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
  let!(:org_admin) { create(:user, company: live, organization: organization, role: "org_admin", name: "Alex OrgAdmin") }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(Resend::Emails).to receive(:send).and_raise("The seed must not send email")
    allow_any_instance_of(ClerkInvitationService).to receive(:create_invitation).and_raise("The seed must not invite anyone")
    unlock_lifecycle_mode!
  end

  after { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }

  def seed!(include_lifecycle_showcase: true)
    DemoCompany::Seed.new(
      organization: organization,
      actor: org_admin,
      include_lifecycle_showcase: include_lifecycle_showcase
    ).call
  end

  def kitchen = Company.demo.find_by!("test_workspace_manifest ->> 'demo_fixture_key' = 'harbor-finch-kitchen'")
  def catering = Company.demo.find_by!("test_workspace_manifest ->> 'demo_fixture_key' = 'harbor-finch-catering'")
  def market = Company.demo.find_by!("test_workspace_manifest ->> 'demo_fixture_key' = 'harbor-finch-market'")
  def worker(first, last) = Employee.find_by!(company: market, first_name: first, last_name: last)

  def market_snapshot
    [
      Employee.where(company: market).count,
      PayPeriod.where(company: market).count,
      EmployeeVerificationItem.where(company: market).count,
      EmployeeReadinessOverride.where(company: market).count,
      AdminOverride.where(company: market).count,
      EmployeeW4Election.where(company: market).count,
      EmployeeCompensationChange.where(company: market).count,
      EmployeeStatusEvent.where(company: market).count,
      ClientOperatingProfile.where(company: market).count
    ]
  end

  it "seeds all client-managed lifecycle showcase scenarios idempotently without altering existing demo history" do
    # Seed baseline Kitchen + Catering first and capture committed demo history.
    baseline = seed!(include_lifecycle_showcase: false)
    expect(baseline.companies.map(&:name)).to eq([ "Harbor Finch Kitchen", "Harbor Finch Catering" ])
    expect(CompanyFeatures.for(kitchen).employee_lifecycle_mode).to eq("approval_first")
    expect(CompanyFeatures.for(catering).employee_lifecycle_mode).to eq("approval_first")

    kitchen_history_before = [
      HistoricalImportBatch.where(company: kitchen).count,
      HistoricalPaycheck.where(company: kitchen).count,
      PayPeriod.where(company: kitchen, status: "committed").count,
      PayrollItem.where(company: kitchen).count,
      Employee.where(company: kitchen).count
    ]
    catering_history_before = [
      PayPeriod.where(company: catering, status: "committed").count,
      PayrollItem.where(company: catering).count,
      Employee.where(company: catering).count
    ]

    result = seed!(include_lifecycle_showcase: true)
    expect(result.companies.map(&:name)).to eq([ "Harbor Finch Kitchen", "Harbor Finch Catering", "Harbor Finch Market" ])
    expect(market).to be_demo
    expect(CompanyFeatures.for(market).employee_lifecycle_mode).to eq("client_managed")
    expect(CompanyFeatures.for(kitchen).employee_lifecycle_mode).to eq("approval_first")
    expect(CompanyFeatures.for(catering).employee_lifecycle_mode).to eq("approval_first")

    # Existing committed demo history is untouched.
    expect([
      HistoricalImportBatch.where(company: kitchen).count,
      HistoricalPaycheck.where(company: kitchen).count,
      PayPeriod.where(company: kitchen, status: "committed").count,
      PayrollItem.where(company: kitchen).count,
      Employee.where(company: kitchen).count
    ]).to eq(kitchen_history_before)
    expect([
      PayPeriod.where(company: catering, status: "committed").count,
      PayrollItem.where(company: catering).count,
      Employee.where(company: catering).count
    ]).to eq(catering_history_before)

    draft = market.pay_periods.find_by!(status: "draft")
    roster_ids = PayPeriodDefaultRoster.new(draft).employee_ids

    # 1. Incomplete new hire (missing W-4) excluded from draft pay run
    incomplete = worker("Jordan", "Sample")
    expect(incomplete).to be_readiness_gate_enforced
    incomplete_eval = EmployeeReadinessEvaluator.for_pay_period(incomplete, draft)
    expect(incomplete_eval.status).to eq("incomplete")
    expect(incomplete_eval.missing_keys).to eq([ "tax_form" ])
    expect(roster_ids).not_to include(incomplete.id)

    # 2. Ready new hire
    ready = worker("Morgan", "Example")
    expect(ready).to be_readiness_gate_enforced
    expect(EmployeeReadinessEvaluator.for_pay_period(ready, draft).status).to eq("ready")
    expect(roster_ids).to include(ready.id)

    # 3. Pending To verify items: pay change, W-4 change, direct_deposit missing bank details
    pay_worker = worker("Casey", "Fixture")
    expect(pay_worker.payroll_rate_on(draft.end_date)).to eq(18.75)
    expect(EmployeeVerificationItem.pending_verification.find_by!(company: market, employee: pay_worker, event_kind: "compensation_change")).to be_present

    w4_worker = worker("Taylor", "Sample")
    expect(w4_worker.w4_election_on(draft.pay_date)&.filing_status).to eq("married")
    expect(EmployeeVerificationItem.pending_verification.find_by!(company: market, employee: w4_worker, event_kind: "w4_change")).to be_present

    dd_worker = worker("Avery", "Example")
    expect(dd_worker.payment_delivery_method).to eq("direct_deposit")
    expect(dd_worker.bank_routing_number_encrypted).to be_blank
    dd_item = EmployeeVerificationItem.pending_verification.find_by!(company: market, employee: dd_worker, event_kind: "payment_method_change")
    expect(dd_item.metadata["direct_deposit_missing_bank_details"]).to be(true)
    expect(EmployeeReadinessEvaluator.for_pay_period(dd_worker, draft).direct_deposit_missing_bank_details?).to be(true)

    # 4. Item returned to client with note
    returned_worker = worker("Riley", "Fixture")
    returned_item = EmployeeVerificationItem.returned_to_client.find_by!(company: market, employee: returned_worker)
    expect(returned_item.return_note).to include("signed date")

    # 5. Termination with final-pay notes
    term_worker = worker("Jamie", "Sample")
    expect(term_worker.status).to eq("terminated")
    term_item = EmployeeVerificationItem.pending_verification.find_by!(company: market, employee: term_worker, event_kind: "termination")
    expect(term_item.metadata["final_pay_notes"]).to include("PTO")

    # 6. Rehire
    rehire_worker = worker("Quinn", "Example")
    expect(rehire_worker.status).to eq("active")
    expect(rehire_worker).to be_readiness_gate_enforced
    expect(rehire_worker.employee_status_events.order(:effective_date, :id).pluck(:event_type)).to eq(%w[terminated reactivated])
    expect(EmployeeVerificationItem.pending_verification.find_by!(company: market, employee: rehire_worker, event_kind: "rehire")).to be_present

    # 7. Name-only possible-self action flagged for staff
    self_worker = worker("Sloane", "Fixture")
    self_item = EmployeeVerificationItem.pending_verification.find_by!(company: market, employee: self_worker, event_kind: "termination")
    expect(self_item.metadata).to include(
      "possible_self_lifecycle_action" => true,
      "own_record_signal" => "name_only"
    )

    # 8. Org-admin readiness override with Pub 15-T default withholding
    override_worker = worker("Parker", "Sample")
    expect(override_worker).to be_readiness_gate_enforced
    expect(EmployeeReadinessEvaluator.for_pay_period(override_worker, draft).missing_keys).to eq([ "tax_form" ])
    override = override_worker.employee_readiness_overrides.active.find_by!(pay_period: draft)
    expect(override.default_w4_acknowledged).to be(true)
    expect(override.default_w4_election&.source).to eq("default_withholding")
    expect(override.default_w4_election&.filing_status).to eq("single")
    expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: draft, employee: override_worker)).to be_nil
    expect(roster_ids).to include(override_worker.id)

    # Grandfathered worker with missing DOB & NULL payment method stays payable
    grandfathered = worker("Drew", "Example")
    expect(grandfathered).not_to be_readiness_gate_enforced
    expect(EmployeeReadinessEvaluator.for_pay_period(grandfathered, draft).status).to eq("missing_items")
    expect(roster_ids).to include(grandfathered.id)

    # Synthetic data check: 900-prefix SSNs, no real Guam streets, no emails sent.
    market_employees = Employee.where(company: market)
    expect(market_employees.map(&:ssn_digits)).to all(start_with("900"))
    expect(([ market.address_line1 ] + market_employees.map(&:address_line1)).join("\n"))
      .not_to match(/Marine Corps|Chalan Santo Papa|Chalan Pasaheru|Route 8|Pale San Vitores/i)
    expect(PortalNotificationDelivery.where(status: "sent").count).to eq(0)

    # Idempotency check: second run is a strict no-op.
    first_snapshot = market_snapshot
    rerun = seed!(include_lifecycle_showcase: true)
    expect(rerun.employees_created).to eq(0)
    expect(rerun.periods_committed).to eq(0)
    expect(market_snapshot).to eq(first_snapshot)
  end
end
