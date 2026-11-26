# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

# Every YTD figure on an earnings statement comes from one live, filtered
# source, so a statement reconciles with itself, with the check stub and with
# W-2GU, and the staff snapshot follows every correction that moves it.
RSpec.describe "Earnings statement YTD consistency" do
  include HistoricalYtdBridgeFixtureHelper

  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, name: "Ledger Test Co") }
  let(:employee) { create(:employee, company: company, first_name: "Robin", last_name: "Example") }

  def committed_period(pay_date, start_date: pay_date - 12, end_date: pay_date - 5)
    create(:pay_period, :committed, company: company, start_date: start_date, end_date: end_date, pay_date: pay_date)
  end

  def item_for(period, worker: employee, **attributes)
    create(:payroll_item, company: company, employee: worker, pay_period: period, employment_type: "hourly",
      pay_rate: 20, hours_worked: 50, gross_pay: 1_000, withholding_tax: 100, social_security_tax: 62,
      medicare_tax: 14.50, net_pay: 823.50, **attributes)
  end

  def ytd_summary(item)
    text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join("\n")
    text.split("YEAR-TO-DATE SUMMARY").last.gsub(/\s+/, " ")
  end

  def tax_ytd(statement)
    statement.fetch(:taxes).to_h { |row| [ row.fetch(:label), row.fetch(:ytd) ] }
  end

  it "prints tax and net YTD from the same live totals as YTD gross, not a stale saved snapshot" do
    item_for(committed_period(Date.new(2026, 3, 13)))
    # Saved before the earlier check counted, as after an out-of-order commit.
    current = item_for(committed_period(Date.new(2026, 3, 27)), ytd_gross: 1_000, ytd_withholding_tax: 100,
      ytd_social_security_tax: 62, ytd_medicare_tax: 14.50, ytd_net: 823.50)

    statement = PayStubGenerator.new(current).statement

    expect(statement.fetch(:ytd)).to eq(gross: 2_000.to_d, net: 1_647.to_d)
    expect(tax_ytd(statement)).to eq("Guam income tax" => 200.to_d, "Social Security (6.2%)" => 124.to_d,
      "Medicare" => 29.to_d)
    expect(ytd_summary(current)).to include("Gross Earnings $2,000.00", "Guam income tax $200.00",
      "Social Security $124.00", "Medicare $29.00", "Net Pay $1,647.00")
    expect(PayStubGenerator.new(current).send(:ytd_total_deductions)).to eq(353.to_d)
  end

  it "leaves out an opening balance dated after the paycheck and live pay already inside the balance" do
    # A run paid before the bridge was activated: the balance already contains it.
    inside = item_for(committed_period(Date.new(2026, 7, 15)))
    apply_historical_ytd_balance(company: company, employee: employee, through_pay_date: Date.new(2026, 7, 31),
      gross_pay: 25_000, net_pay: 20_000, federal_income_tax: 2_500, social_security_tax: 1_550, medicare_tax: 362.50)
    later = item_for(committed_period(Date.new(2026, 8, 14), start_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 10)))

    expect(PayStubGenerator.new(inside).statement.fetch(:ytd)).to eq(gross: 1_000.to_d, net: 823.50.to_d)
    expect(tax_ytd(PayStubGenerator.new(inside).statement)).to include("Guam income tax" => 100.to_d)

    statement = PayStubGenerator.new(later).statement
    expect(statement.fetch(:ytd)).to eq(gross: 26_000.to_d, net: 20_823.50.to_d)
    expect(tax_ytd(statement)).to include("Guam income tax" => 2_600.to_d, "Social Security (6.2%)" => 1_612.to_d)
    expect(PayrollEarningsYtdBreakdown.new(later).source_items).to eq([ later ])
    expect(CheckGenerator.new(later).render_input_payload.fetch("summary")).to include(
      "ytd_gross" => "26,000.00", "ytd_net_pay" => "20,823.50"
    )
  end

  it "shows the saved Additional Medicare on the current check and leaves bridged YTD combined" do
    apply_historical_ytd_balance(company: company, employee: employee, through_pay_date: Date.new(2026, 7, 31),
      medicare_tax: 362.50)
    later = item_for(committed_period(Date.new(2026, 8, 14), start_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 10)))
    later.update_columns(medicare_tax: 20, additional_medicare_tax: 5.50)

    expect(PayStubGenerator.new(later).statement.fetch(:taxes)).to include(
      { label: "Medicare", amount: 14.50.to_d, ytd: 382.50.to_d },
      { label: "Additional Medicare", amount: 5.50.to_d, ytd: nil }
    )
  end

  describe "with an activated QuickBooks bridge revised by a reviewed adjustment" do
    let(:company) { create(:company, name: "Ledger Test Co", historical_payroll_enabled: true) }
    let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

    after { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }

    def preview_bridge
      batch = QuickbooksHistory::ImportService.new(company: company,
        files: quickbooks_history_uploads + quickbooks_tax_wage_uploads, actor: actor).call.batch
      bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
      QuickbooksHistory::ClientBootstrapApplyService.new(bootstrap: bootstrap, actor: actor,
        acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT).call
      QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor)
        .apply!(acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT)
      approve_historical_cutover(batch, actor: actor)
      QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor).lock!
      QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
    end

    def apply!(bridge)
      QuickbooksHistory::YtdBridgeApplyService.new(bridge: bridge, actor: actor,
        acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT).call
    end

    def record_adjustment!(paycheck)
      input = { kind: "correction", effective_pay_date: paycheck.pay_date.iso8601, reason: "Correct source wages",
                idempotency_key: "statement-ytd-adjustment", gross_pay: 100, federal_income_tax: 10,
                social_security_tax: 6.20, medicare_tax: 1.45 }
      preview = HistoricalPayroll::AdjustmentPreviewService.new(paycheck: paycheck, actor: actor, attributes: input).call
      adjustment = HistoricalPayroll::AdjustmentCreateService.new(paycheck: paycheck, actor: actor, attributes: input,
        acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT, preview_digest: preview.digest).call
      %w[filing_reviewed_no_amendment downstream_impact_acknowledged].each do |event_type|
        HistoricalPayroll::AdjustmentEventService.new(adjustment: adjustment, actor: actor, event_type: event_type).call
      end
    end

    it "reconciles the statement with W-2GU and refreshes the saved snapshot when the revision activates" do
      bridge = preview_bridge
      apply!(bridge)
      worker = company.employees.find_by!(first_name: "Alice", last_name: "Worker")
      period = committed_period(Date.new(2024, 7, 17), start_date: Date.new(2024, 6, 28), end_date: Date.new(2024, 7, 11))
      opening = worker.ytd_totals_before(year: 2024, pay_date: period.pay_date, pay_period_id: period.id)
      item = item_for(period, worker: worker, gross_pay: 2_000, withholding_tax: 150, social_security_tax: 124,
        medicare_tax: 29, net_pay: 1_697, hours_worked: 100, fit_taxable_wages: 2_000,
        social_security_taxable_wages: 2_000, social_security_taxable_tips: 0, medicare_taxable_wages: 2_000,
        ytd_gross: opening[:gross_pay] + 2_000, ytd_withholding_tax: opening[:withholding_tax] + 150,
        ytd_social_security_tax: opening[:social_security_tax] + 124, ytd_medicare_tax: opening[:medicare_tax] + 29,
        ytd_net: opening[:net_pay] + 1_697)

      record_adjustment!(bridge.historical_import_batch.historical_paychecks.where(employee: worker).order(:id).first)
      revised = QuickbooksHistory::YtdBridgePreviewService.new(batch: bridge.historical_import_batch, actor: actor).call
      expect(revised).to be_ready_to_apply
      apply!(revised)

      w2 = W2GuAggregator.new(company, 2024).generate.fetch(:employees).find { |row| row[:employee_id] == worker.id }
      statement = PayStubGenerator.new(item.reload).statement
      expect(tax_ytd(statement)).to eq(
        "Guam income tax" => w2.fetch(:box2_federal_income_tax_withheld).to_d,
        "Social Security (6.2%)" => w2.fetch(:box4_social_security_tax_withheld).to_d,
        "Medicare" => w2.fetch(:box6_medicare_tax_withheld).to_d
      )
      expect(tax_ytd(statement).fetch("Guam income tax")).to eq(opening[:withholding_tax].to_d + 10 + 150)
      expect(statement.dig(:ytd, :gross)).to eq(opening[:gross_pay].to_d + 100 + 2_000)
      expect(item).to have_attributes(ytd_gross: opening[:gross_pay].to_d + 100 + 2_000,
        ytd_withholding_tax: opening[:withholding_tax].to_d + 10 + 150,
        ytd_social_security_tax: opening[:social_security_tax].to_d + 6.20 + 124)
    end
  end

  it "refreshes a later run's saved snapshot when an earlier-dated run commits after it" do
    commit = lambda do |start_date, end_date, pay_date|
      period = create(:pay_period, company: company, start_date: start_date, end_date: end_date, pay_date: pay_date)
      item = build(:payroll_item, company: company, employee: employee, pay_period: period,
        employment_type: "hourly", pay_rate: 20, hours_worked: 10)
      PayrollCalculator.for(employee, item).calculate
      item.save!
      period.update!(status: "approved")
      PayPeriodLifecycleService.new(pay_period: period, actor: nil).commit!
      item.reload
    end
    later = commit.call(Date.new(2024, 5, 18), Date.new(2024, 5, 24), Date.new(2024, 5, 31))
    expect(later.ytd_gross).to eq(later.gross_pay)

    earlier = commit.call(Date.new(2024, 5, 1), Date.new(2024, 5, 10), Date.new(2024, 5, 17))

    expect(later.reload).to have_attributes(ytd_gross: later.gross_pay + earlier.gross_pay,
      ytd_withholding_tax: later.withholding_tax + earlier.withholding_tax, ytd_net: later.net_pay + earlier.net_pay)
  end

  it "refreshes an employee's later snapshots in a fixed number of queries" do
    periods = (0..6).map { |index| committed_period(Date.new(2026, 1, 16) + (14 * index)) }
    other = create(:employee, company: company, first_name: "Sam", last_name: "Sample")
    later = periods.map { |period| item_for(period) }.drop(1)
    periods.first(3).each { |period| item_for(period, worker: other) }
    statements = lambda do |worker|
      total = 0
      counter = ->(*, payload) { total += 1 unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        PayrollYtdSnapshotRefresh.after(pay_period: periods.first, employee_ids: [ worker.id ])
      end
      total
    end

    # The first refresh writes each later snapshot; an unchanged one writes none.
    [ employee, other ].each { |worker| statements.call(worker) }
    expect(later.map { |item| item.reload.ytd_gross }).to eq((2..7).map { |checks| 1_000.to_d * checks })
    expect(statements.call(employee)).to eq(statements.call(other))
  end

  it "keeps itemized 401(k) contributions in the retirement snapshot after a pay date correction" do
    period = committed_period(Date.new(2026, 6, 19))
    item = item_for(period, retirement_payment: 0)
    field = create(:payroll_field_definition, company: company, name: "Plan 401(k)", kind: "deduction",
      tax_treatment: "pre_tax_deduction", category: "retirement", reporting_group: "401k_pre_tax")
    create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: field, amount: 150,
      reporting_group: "401k_pre_tax")
    expect(PayrollRetirementTotals.for_item(item.reload)).to include(retirement: 150.to_d)

    PayPeriodPayDateCorrectionService.call(pay_period: period, new_pay_date: Date.new(2026, 6, 20),
      reason: "Correct the printed pay date", actor: create(:user, company: company, organization: company.organization))

    expect(item.reload.ytd_retirement).to eq(150.to_d)
  end

  describe "check stub parity" do
    it "labels federal tax with the W-4 saved on the paycheck, not the employee's later W-4" do
      item = item_for(committed_period(Date.new(2026, 4, 17)), tax_rule_snapshot: {
        "w4" => { "step2_multiple_jobs" => false, "step4a_other_income" => 0.0, "step4b_deductions" => 0.0 }
      })
      employee.update_columns(w4_step2_multiple_jobs: true, w4_step4a_other_income: 1_200)

      label = CheckGenerator.new(item.reload).render_input_payload.fetch("tax_rows").first.first
      expect(label).to eq("Guam income tax")

      item.update_columns(tax_rule_snapshot: { "w4" => { "step2_multiple_jobs" => true, "step4a_other_income" => 0.0,
                                                         "step4b_deductions" => 500.0 } })
      expect(CheckGenerator.new(item.reload).render_input_payload.fetch("tax_rows").first.first)
        .to eq("Guam income tax (Step2,4b)")
    end

    it "prints a signed correction's own adjustment line so the check stub foots to its gross" do
      original_period = committed_period(Date.new(2026, 4, 3))
      original = item_for(original_period, pay_rate: 25, hours_worked: 4, gross_pay: 100)
      period = create(:pay_period, :committed, company: company, cycle: "supplemental", run_purpose: "correction",
        run_purpose_source: "system_correction", includes_base_salary: false, includes_recurring_items: false,
        corrects_pay_period_id: original_period.id, start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 4, 8),
        pay_date: Date.new(2026, 4, 10))
      correction = create(:payroll_item, :with_check, company: company, employee: employee, pay_period: period,
        correction_for_payroll_item: original, pay_rate: 25, hours_worked: -1, gross_pay: -30, net_pay: -27.71,
        social_security_tax: -1.86, medicare_tax: -0.43)

      rows = CheckGenerator.new(correction).send(:pay_rows)
      expect(rows.first.first(4)).to eq([ "Taxable earnings adjustment", "-", "-", "-30.00" ])
      expect(rows.length).to eq(2)
    end
  end

  it "omits employee tax lines from a contractor's printed statement as the employee app does" do
    contractor = create(:employee, :contractor, company: company)
    item = create(:payroll_item, company: company, employee: contractor, pay_period: committed_period(Date.new(2026, 4, 17)),
      employment_type: "contractor", pay_rate: 500, hours_worked: 0, salary_override: 500, gross_pay: 500, net_pay: 500)
    text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join("\n")

    expect(PayStubGenerator.new(item).statement.fetch(:taxes)).to eq([])
    expect(text).not_to include("Social Security", "Medicare", "Guam income tax")
    expect(text).to include("NET PAY", "$500.00")
  end

  it "keeps an employee paycheck's tax lines after the worker becomes a contractor" do
    item = item_for(committed_period(Date.new(2026, 4, 17)), withholding_tax: 115.64, social_security_tax: 99.20,
      medicare_tax: 23.20, net_pay: 761.96)
    employee.update_columns(employment_type: "contractor", contractor_type: "individual", contractor_pay_type: "flat_fee")
    generator = PayStubGenerator.new(item.reload)
    text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n").gsub(/\s+/, " ")

    expect(generator.statement.fetch(:taxes).map { |row| row.fetch(:amount) }).to eq([ 115.64.to_d, 99.20.to_d, 23.20.to_d ])
    expect(text).to include("Guam income tax $115.64", "Social Security (6.2%) $99.20", "Medicare $23.20",
      "TOTAL DEDUCTIONS $238.04", "Guam income tax $115.64")
  end

  describe "printed money" do
    it "rounds half-cents up and puts the sign before the dollar sign on statements and checks" do
      item = item_for(committed_period(Date.new(2026, 4, 17)), gross_pay: -25, net_pay: -23.09, withholding_tax: 0,
        social_security_tax: -1.55, medicare_tax: -0.36, hours_worked: 0)
      text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join("\n")
      stub = PayStubGenerator.new(item)
      check = CheckGenerator.new(item)

      expect(text).to include("-$25.00", "-$23.09")
      expect(text).not_to include("$-")
      expect(stub.send(:format_currency, BigDecimal("10.005"))).to eq("$10.01")
      expect(stub.send(:format_currency, 1_234_567.891)).to eq("$1,234,567.89")
      expect(check.send(:fn, BigDecimal("10.005"))).to eq("10.01")
      expect(check.send(:fd, -12.34)).to eq("-$12.34")
      expect(FirstHawaiianFourUpCheckGenerator.allocate.send(:fd, -12.34)).to eq("-$12.34")
      expect(W2GuPdfGenerator.allocate.send(:fmt, BigDecimal("10.005"))).to eq("$10.01")
    end
  end

  describe "employer address" do
    it "prints whichever address parts exist on the statement, matching W-2GU" do
      company.update_columns(address_line1: nil, address_line2: nil, city: "Hagatna", state: "GU", zip: "96910")
      item = item_for(committed_period(Date.new(2026, 4, 17)))
      text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.first.text

      expect(text).to include("Hagatna, GU 96910")
      expect(company.full_address).to eq("Hagatna, GU 96910")
      company.update_columns(address_line1: "1 Example Way", city: nil, state: nil, zip: nil)
      expect(company.reload.full_address).to eq("1 Example Way")
    end
  end
end
