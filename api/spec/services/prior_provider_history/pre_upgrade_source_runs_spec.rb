# frozen_string_literal: true

require "rails_helper"

# Mirrors the read-only production shape recorded on 2026-11-02 for the first
# prior-provider client: three salaried per-period employees whose profile
# frequency is semimonthly, but whose 20 calculated (never approved/committed)
# regular runs were created by the pre-staging-v2 code with 14-day periods,
# three 21-day periods and the pay date on the period end. No check numbers,
# liability postings, YTD rows or import batches exist.
RSpec.describe "Prior-provider history from pre-upgrade calculated runs", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  PERIOD_ENDS = %w[
    01-14 01-28 02-11 02-25 03-11 03-25 04-08 04-22 05-13 05-27
    06-10 06-24 07-08 07-22 08-12 08-26 09-09 09-23 10-07 10-28
  ].map { |day| Date.iso8601("2026-#{day}") }.freeze

  around { |example| travel_to(Time.utc(2026, 11, 2, 2)) { example.run } }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Api::V1::Admin::PriorProviderHistoriesController).to receive(:current_user) { @actor }
    allow_any_instance_of(Api::V1::Admin::PriorProviderHistoriesController).to receive(:current_company_id) { @company.id }
  end

  after do
    HistoricalImportSourceFile.where(company: @company).find_each { |file| R2StorageService.new.delete(file.storage_key) } if @company
  end

  # Calculate with the current engine, then remove every calculation artifact
  # staging-v2 added so the saved rows match what the older code persisted.
  def pre_upgrade_fixture
    @company = create(:company, historical_payroll_enabled: true, name: "Prior-provider real-shape fixture", pay_frequency: "semimonthly", next_check_number: 701)
    @actor = create(:user, company: @company, organization: @company.organization, role: "admin")
    create(:tax_table, tax_year: 2026, pay_frequency: "semimonthly", ss_wage_base: 184_500) unless TaxTable.for_year(2026).exists?
    @employees = [ 1_500, 1_400, 1_400 ].each_with_index.map do |amount, index|
      create(:employee, :salary, company: @company, first_name: "Salaried", last_name: "Employee #{index + 1}", salary_type: "per_period",
        pay_rate: amount, pay_frequency: "semimonthly", payment_delivery_method: "paper_check")
    end
    start_date = Date.new(2026, 1, 1)
    @runs = PERIOD_ENDS.each_with_index.map do |end_date, index|
      @employees.last.update!(pay_rate: 1_250) if index == 2
      run = create(:pay_period, company: @company, start_date: start_date, end_date: end_date, pay_date: end_date)
      @employees.each do |employee|
        create(:payroll_item, :salary, company: @company, employee: employee, pay_period: run, pay_rate: employee.pay_rate).calculate!
      end
      run.update!(status: "calculated")
      run.payroll_items.each do |item|
        item.update_columns(tax_rule_snapshot: item.tax_rule_snapshot.except("annual_fica_context"),
          calculation_context_snapshot: item.calculation_context_snapshot.to_h.except("earnings_rounding", "built_in_employer_match_mirrors"))
      end
      start_date = end_date + 1
      run
    end
  end

  def payload_from(candidates)
    {
      "tax_year" => 2026, "takeover_on" => "2026-11-01", "provider_name" => "Previous Payroll Provider",
      "same_employer_confirmed" => true, "complete_history_confirmed" => true,
      "periods" => candidates.map do |period|
        period.merge("register_totals" => period.fetch("calculated_totals").slice(*PriorProviderHistory::Amounts::REGISTER_FIELDS),
          "source_reference" => "Paid provider register #{period.fetch('pay_date')}, page 1")
      end,
      "identities" => @employees.to_h { |employee| [ employee.id.to_s, { "source_name" => employee.full_name, "ssn_last4" => employee.ssn_last_four } ] }
    }
  end

  def side_effects
    [ PayrollItem.where(company: @company).where.not(check_number: nil).count, @company.reload.next_check_number,
      PayrollLiabilityPosting.where(company: @company).count, PayrollLiabilityEntry.where(company_id: @company.id).count,
      DirectDepositPaymentConfirmation.count, NonEmployeeCheck.where(company: @company).count, LoanTransaction.count,
      Form500Filing.where(company: @company).count, PayrollFilingEvent.where(company: @company).count,
      PayPeriod.where(id: @runs.map(&:id)).order(:id).pluck(:tax_sync_status, :tax_sync_attempts, :tax_synced_at),
      EmployeeYtdTotal.where(employee_id: @company.employees.select(:id)).count, CompanyYtdTotal.where(company: @company).count,
      ActiveJob::Base.queue_adapter.enqueued_jobs.size, ActionMailer::Base.deliveries.size ]
  end

  it "selects and converts 14/21-day runs on a semimonthly roster without recalculating, then calculates the first live payroll normally" do
    pre_upgrade_fixture
    expect(@runs.map { |run| (run.end_date - run.start_date).to_i + 1 }).to eq([ 14 ] * 8 + [ 21 ] + [ 14 ] * 5 + [ 21 ] + [ 14 ] * 4 + [ 21 ])
    expect(@runs.map { |run| run.pay_date == run.end_date }.uniq).to eq([ true ])
    expect(@runs.map { |run| run.payroll_items.sum(:gross_pay) }).to eq([ 4_300, 4_300 ] + [ 4_150 ] * 18)
    expect(@employees.map(&:pay_frequency).uniq).to eq([ "semimonthly" ])
    # The upgraded approval path would demand a fresh calculation for these rows.
    expect { PayPeriodLifecycleService.new(pay_period: @runs.first, actor: @actor).approve! }
      .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, EmployeeYearFicaContext::MISSING_MESSAGE)
    expect(@runs.first.reload.status).to eq("calculated")

    items_before = PayrollItem.where(pay_period_id: @runs.map(&:id)).order(:id).map(&:attributes)
    get "/api/v1/admin/prior_provider_histories"
    expect(response).to have_http_status(:ok)
    candidates = response.parsed_body.fetch("candidates")
    expect(response.parsed_body.fetch("eligible_run_count")).to eq(20)
    expect(candidates.map { |period| period.fetch("run_id") }).to eq(@runs.map(&:id))
    candidates.flat_map { |period| period.fetch("paychecks") }.each do |row|
      expect(row.values_at("fit_taxable_wages", "social_security_taxable_wages", "medicare_taxable_wages")).to all(be_present)
    end

    payload = payload_from(candidates)
    post "/api/v1/admin/prior_provider_histories/preview", params: { payload: payload }, as: :json
    expect(response.parsed_body).to include("ready" => true, "errors" => [])
    before = side_effects
    onboarding = convert_history(@company, @actor, payload, key: "pre-upgrade-history-2026")
    expect(PayrollItem.where(pay_period_id: @runs.map(&:id)).order(:id).map(&:attributes)).to eq(items_before)
    expect(@runs.map { |run| run.reload.status }.uniq).to eq([ "retired_history" ])
    periods = onboarding.historical_import_batch.historical_pay_periods.order(:pay_date)
    expect(periods.map { |period| [ period.start_date, period.end_date, period.pay_date ] }).to eq(@runs.map { |run| [ run.start_date, run.end_date, run.pay_date ] })
    expect(onboarding.historical_import_batch.historical_paychecks.count).to eq(60)
    expect(side_effects).to eq(before)

    activate_history(onboarding, @actor)
    expect(side_effects).to eq(before)
    annual = @employees.to_h { |employee| [ employee.id, PayrollItem.where(pay_period_id: @runs.map(&:id), employee: employee).sum(:gross_pay) ] }
    @employees.each do |employee|
      balance = HistoricalEmployeeYtdBalance.find_by!(company: @company, employee: employee)
      expect(balance).to have_attributes(medicare_taxable_wages: annual.fetch(employee.id), through_pay_date: Date.new(2026, 10, 28))
    end

    # The first live run starts the day after the imported period end.
    live = create(:pay_period, company: @company, start_date: "2026-10-29", end_date: "2026-11-11", pay_date: "2026-11-11")
    @employees.each do |employee|
      item = create(:payroll_item, :salary, company: @company, employee: employee, pay_period: live, pay_rate: employee.reload.pay_rate)
      item.calculate!
      context = item.reload.tax_rule_snapshot.fetch("annual_fica_context")
      expect(context).to include("version" => EmployeeYearFicaContext::VERSION)
      expect(context).not_to have_key("mode")
      expect(item.ytd_gross).to eq(annual.fetch(employee.id) + item.gross_pay)
      expect(item.social_security_tax).to eq((item.gross_pay * BigDecimal("0.062")).round(2))
      # Imported paychecks engage the conservative imported-history path, which
      # holds without a source review; the verified opening balance remains the
      # authoritative ordinary calculation instead of a source-review hold.
      expect(BelowThresholdFicaContext.new(employee: employee, company: @company, year: 2026, excluding_pay_period_id: live.id).applicable?).to be(true)
    end
    expect(EmployeeYearFicaSourceReview.where(company: @company)).to be_empty
    live.update!(status: "calculated")
    PayPeriodLifecycleService.new(pay_period: live, actor: @actor).approve!
    expect(live.reload.status).to eq("approved")
    expect(side_effects).to eq(before)
    PayPeriodLifecycleService.new(pay_period: live, actor: @actor).commit!
    expect(live.reload.status).to eq("committed")
    expect(HistoricalPaycheck.where(company: @company).where.not(check_number: nil)).to be_empty
    expect(@runs.map { |run| run.reload.status }.uniq).to eq([ "retired_history" ])
    # The release-day runner never selects this client, but its read-only
    # before-inventory covers every company and must stay clean here.
    inventory = PayrollFicaLegacyRecovery.new(company: @company, year: 2026).inventory
    expect(inventory.fetch(:counts)).to include(held: 0, calculable_below_thresholds: 0, complete: 3)
  end

  it "lists an ambiguous pre-upgrade employer contribution as blank for explicit register entry instead of failing selection" do
    pre_upgrade_fixture
    ambiguous = @runs.first.payroll_items.order(:id).first
    allow(PayrollEmployerContributions).to receive(:total).and_call_original
    allow(PayrollEmployerContributions).to receive(:total).with(having_attributes(id: ambiguous.id))
      .and_raise(PayrollComponentMirrors::AmbiguousHistoryError, "Saved payroll field mirror identity is ambiguous")
    get "/api/v1/admin/prior_provider_histories"
    expect(response).to have_http_status(:ok)
    candidates = response.parsed_body.fetch("candidates")
    expect(candidates.size).to eq(20)
    row = candidates.first.fetch("paychecks").find { |check| check.fetch("employee_id") == ambiguous.employee_id }
    expect(row).to include("employer_contributions" => "", "employer_contribution_breakdown" => [])
    payload = payload_from(candidates)
    plan = PriorProviderHistory::Plan.new(company: @company, payload: payload).call
    expect(plan.errors.join).to match(/Employer contributions requires a nonnegative amount/)
    row["employer_contributions"] = "0.0"
    expect(PriorProviderHistory::Plan.new(company: @company, payload: payload_from(candidates)).call.errors).to eq([])
  end
end
