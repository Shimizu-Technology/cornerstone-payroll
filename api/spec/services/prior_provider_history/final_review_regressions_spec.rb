# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Prior-provider final review regressions" do
  include ActiveSupport::Testing::TimeHelpers
  include HistoricalYtdBridgeFixtureHelper

  around { |example| travel_to(Time.utc(2026, 11, 2, 2)) { example.run } }

  after do
    HistoricalImportSourceFile.where(company: @company).find_each { |file| R2StorageService.new.delete(file.storage_key) } if @company
  end

  %w[native manual].each do |source|
    it "holds fresh payroll after undo of #{source} history until a replacement is active" do
      @company, actor, _employees, runs, payload = history_fixture(period_count: 1)
      if source == "manual"
        payload["periods"].first.except!("run_id", "source_digest")
        runs.first.destroy!
      end
      onboarding = convert_history(@company, actor, payload)
      activate_history(onboarding, actor)
      reverse_history(onboarding, actor)
      live = build(:pay_period, company: @company, start_date: "2026-10-29", end_date: "2026-11-11", pay_date: "2026-11-11")
      expect(live.valid?).to be(false)
      expect(live.errors.full_messages.join).to include("replacement prior-provider history")
      expect(live.valid?(:payroll_calculation)).to be(false)
      # A previously persisted or stale record must also fail at finalization.
      live.save!(validate: false)
      service = PayPeriodLifecycleService.new(pay_period: live, actor: actor)
      expect { service.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /replacement prior-provider history/)
      expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /replacement prior-provider history/)
      live.destroy!
      if source == "native"
        payload["periods"].first["source_digest"] = PriorProviderHistory::SourceAdapter.digest(runs.first.reload)
      end
      replacement = convert_history(@company, actor, payload)
      activate_history(replacement, actor)
      expect(PriorProviderHistoryOnboarding.unresolved_reversed_for(@company.id)).not_to exist
      expect { create(:pay_period, company: @company, start_date: "2026-10-29", end_date: "2026-11-11", pay_date: "2026-11-11") }.not_to raise_error
    end
  end

  it "scopes reversed-history holds to the payroll tax year and accepts only an applied compatible replacement bridge" do
    @company, actor, employees, runs, payload = history_fixture(period_count: 1)
    onboarding = convert_history(@company, actor, payload)
    activate_history(onboarding, actor)
    reverse_history(onboarding, actor)
    current = build(:pay_period, company: @company, start_date: "2026-10-29", end_date: "2026-11-11", pay_date: "2026-11-11")
    future = build(:pay_period, company: @company, start_date: "2027-01-01", end_date: "2027-01-14", pay_date: "2027-01-14")
    expect(current.unresolved_prior_provider_history?).to be(true)
    expect(future.unresolved_prior_provider_history?).to be(false)
    expect(future).to be_valid
    last_paid = runs.first.pay_date
    balance = apply_historical_ytd_balance(company: @company, employee: employees.first, through_pay_date: last_paid)
    # A replacement covering only some employees, or stopping short of the
    # undone history's last pay date, must keep the hold.
    expect(current.unresolved_prior_provider_history?).to be(true)
    apply_historical_ytd_balance(company: @company, employee: employees.second, through_pay_date: last_paid)
    apply_historical_ytd_balance(company: @company, employee: employees.third, through_pay_date: last_paid - 1)
    expect(current.unresolved_prior_provider_history?).to be(true)
    expect(current).not_to be_valid
    apply_historical_ytd_balance(company: @company, employee: employees.third, through_pay_date: last_paid)
    expect(current.unresolved_prior_provider_history?).to be(false)
    bridge = balance.historical_ytd_bridge
    batch = bridge.historical_import_batch
    applied_attributes = bridge.attributes.slice("status", "applied_at", "applied_by_id", "apply_acknowledgement")
    bridge.update_columns(status: "previewed", applied_at: nil, applied_by_id: nil, apply_acknowledgement: nil)
    expect(current.unresolved_prior_provider_history?).to be(true)
    bridge.update_columns(applied_attributes)
    batch.update_columns(importer_version: "unsupported-version")
    expect(current.unresolved_prior_provider_history?).to be(true)
    batch.update_columns(importer_version: "quickbooks-online-payroll-v5", status: "applied")
    expect(current.unresolved_prior_provider_history?).to be(true)
    batch.update_columns(status: "locked")
    expect(current.unresolved_prior_provider_history?).to be(false)
    expect(current).to be_valid
    # Replacement YTD can clear a fresh run's hold, never paid-source provenance.
    expect(runs.first.reload.paid_prior_provider_source?).to be(true)
    expect { PayPeriodLifecycleService.new(pay_period: runs.first, actor: actor).approve! }
      .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /already paid/)
  end

  it "prefills 401(k) separately from other pre-tax deductions without changing the total" do
    @company, _actor, _employees, runs, = history_fixture(period_count: 1)
    item = runs.first.payroll_items.first
    type = DeductionType.create!(company: @company, name: "Example pre-tax benefit", category: "pre_tax")
    item.payroll_item_deductions.create!(deduction_type: type, label: type.name, category: "pre_tax", amount: 25)
    item.update!(retirement_payment: 100, total_deductions: 478, net_pay: 1522)
    row = PriorProviderHistory::SourceAdapter.candidate(runs.first).fetch("paychecks").find { |check| check["employee_id"] == item.employee_id }
    expect(row["pretax_deductions"].to_d).to eq(125)
    expect(row["pretax_deduction_breakdown"]).to eq([
      { "label" => "401(k) pre-tax retirement", "amount" => "100.0" },
      { "label" => "Other pre-tax deductions", "amount" => "25.0" }
    ])
    expect(row["pretax_deduction_breakdown"].sum { |part| part["amount"].to_d }).to eq(row["pretax_deductions"].to_d)
    expect(row["retirement"].to_d).to eq(100)
    expect(row["after_tax_deduction_breakdown"]).to eq([])
  end

  it "reconciles inclusive source gross and reports explicit deductions even with generic register labels" do
    @company, actor, employees, _runs, payload = history_fixture(period_count: 1)
    period = payload["periods"].first
    row = period["paychecks"].first
    row.merge!("non_taxable_pay" => "100.00", "pretax_deductions" => "100.00", "retirement" => "100.00",
      "roth_retirement" => "20.00", "insurance" => "30.00", "loans" => "10.00", "after_tax_deductions" => "60.00",
      "fit_taxable_wages" => "1800.00", "social_security_taxable_wages" => "1900.00", "medicare_taxable_wages" => "1900.00",
      "federal_income_tax" => "100.00", "social_security_tax" => "117.80", "medicare_tax" => "27.55",
      "employer_social_security_tax" => "117.80", "employer_medicare_tax" => "27.55", "net_pay" => "1594.65",
      "pretax_deduction_breakdown" => [ { "label" => "Pre-tax deductions", "amount" => "100.00" } ],
      "after_tax_deduction_breakdown" => [ { "label" => "Post-tax deductions", "amount" => "60.00" } ])
    period["register_totals"] = PriorProviderHistory::Amounts.totals(period["paychecks"]).slice(*PriorProviderHistory::Amounts::REGISTER_FIELDS)
    onboarding = convert_history(@company, actor, payload)
    activate_history(onboarding, actor)
    paycheck = onboarding.historical_import_batch.historical_paychecks.find_by!(employee: employees.first)
    report = ImportedPayrollRegister.new(company_id: @company.id, historical_pay_period_id: paycheck.historical_pay_period_id).call
    register_row = report[:employees].find { |record| record[:employee_id] == employees.first.id }
    expect(paycheck.gross_pay).to eq(2_000)
    expect(register_row).to include(gross_pay: 1_900, non_taxable_pay: 100, retirement_payment: 100,
      roth_retirement_payment: 20, total_retirement_payment: 120, insurance_payment: 30, loan_payment: 10, historical_loan_deductions_unclassified: 10)
    csv = CSV.parse(PayrollRegisterCsvExporter.new(report).generate, headers: true)
    expect(csv.first["Previous Provider Loans (Type Not Recorded)"]).to eq("10.00")
    expect(csv[-1]["Previous Provider Loans (Type Not Recorded)"]).to eq("10.00")
    expect(csv.first["Straight Loan (One-Time)"]).to eq("0.00")
    expect(csv.first["Installment Loan (Recurring)"]).to eq("0.00")
    pdf = PayrollRegisterPdfGenerator.new(report)
    column = pdf.send(:employee_table_columns).find { |entry| entry[:key] == :historical_loan_deductions_unclassified }
    expect(column[:label]).to eq("Previous Provider Loans (Type Not Recorded)")
    expect(pdf.send(:employee_table_value, register_row, column[:key])).to include("10.00")
    sheets = Api::V1::Admin::ReportsController.new.send(:payroll_register_sheets, report)
    employee_sheet = sheets.find { |sheet| sheet[:name] == "Employees" }
    loan_column = employee_sheet[:rows][3].index("Previous Provider Loans (Type Not Recorded)")
    expect(employee_sheet[:rows][4][loan_column]).to eq(10)
    expect(employee_sheet[:rows].last[loan_column]).to eq(10)
    expect(PayrollRegisterReconciliation.review_rows(report)).to be_empty
    reporting = UnifiedPayrollReporting.new(company_id: @company.id, period: PayrollReportingPeriod.from_params({ year: 2026 }))
    expect(reporting.add_historical_to_employee_row({}, [ paycheck ])).to include(
      retirement: 100, roth_retirement: 20, health_insurance_deductions: 30, historical_loan_deductions_unclassified: 10)
    expect(HistoricalEmployeeYtdBalance.find_by!(employee: employees.first)).to have_attributes(retirement: 100, roth_retirement: 20, insurance: 30, loans: 10)
  end

  it "refuses a replayed request whose history was undone, then records the same history under a new request" do
    @company, actor, _employees, runs, payload = history_fixture(period_count: 1)
    payload["periods"].first.except!("run_id", "source_digest")
    runs.first.destroy!
    onboarding = convert_history(@company, actor, payload, key: "undone-request-2026")
    reverse_history(onboarding, actor)
    replay = PriorProviderHistory::Conversion.new(company: @company, actor: actor, payload: payload, preview_digest: onboarding.preview_digest,
      idempotency_key: "undone-request-2026", files: [ history_upload ], acknowledgement: PriorProviderHistory::Conversion::ACKNOWLEDGEMENT)
    expect { replay.call }.to raise_error(ArgumentError, PriorProviderHistory::Conversion::REVERSED_REPLAY_ERROR)
    expect(PriorProviderHistoryOnboarding.where(company: @company).pluck(:status)).to eq([ "reversed" ])
    expect(HistoricalImportBatch.where(company: @company).count).to eq(1)
    again = convert_history(@company, actor, payload, key: "rerecord-request-2026")
    expect(again).not_to eq(onboarding)
    expect(again.status).to eq("converted")
  end

  it "names recorded prior-provider history, not QuickBooks, in first-live boundary errors" do
    @company, actor, _employees, runs, payload = history_fixture(period_count: 1)
    activate_history(convert_history(@company, actor, payload), actor)
    source = runs.first.reload
    early = build(:pay_period, company: @company, start_date: source.end_date, end_date: source.end_date + 13, pay_date: source.pay_date)
    expect(early).not_to be_valid
    expect(early.errors[:start_date]).to include("must be after the recorded prior-provider history ending #{source.end_date.strftime('%m/%d/%Y')}")
    expect(early.errors[:pay_date]).to include("must be after the recorded prior-provider history paid through #{source.pay_date.strftime('%m/%d/%Y')}")
    expect(early.errors.full_messages.join).not_to include("QuickBooks")
  end

  describe "report source labels" do
    let(:controller) { Api::V1::Admin::ReportsController.new }
    let(:legacy_sheet_fields) do
      [ "Field", "Basis", "Cornerstone payrolls", "Cornerstone paychecks", "QuickBooks payrolls", "QuickBooks paychecks",
        "QuickBooks opening summaries", "Excluded unlinked QuickBooks paychecks", "Excluded unlinked QuickBooks gross pay",
        "Excluded unlinked QuickBooks net pay", "Historical ledger adjustments", "Historical adjustment gross delta",
        "Historical adjustment net delta", "Historical YTD bridge applied", "Historical YTD through pay date", "Source handling" ]
    end
    let(:counts) do
      { payroll_count: 2, paycheck_count: 6, record_count: 6, opening_summary_count: 0,
        excluded_unlinked_paycheck_count: 1, excluded_unlinked_gross_pay: 10, excluded_unlinked_net_pay: 8 }
    end

    it "adds prior-provider rows to the Payroll Sources sheet only when the report has provider history" do
      summary = { mode: "locked_quickbooks_plus_committed_cornerstone", cornerstone: {}, quickbooks: counts, adjustments: {}, historical_ytd_bridge: {} }
      legacy = controller.send(:payroll_source_summary_sheet, { source_summary: summary })
      expect(legacy[:rows].map(&:first)).to eq(legacy_sheet_fields)
      expect(legacy[:rows].assoc("QuickBooks paychecks")).to eq([ "QuickBooks paychecks", 6 ])
      provider = controller.send(:payroll_source_summary_sheet, { source_summary: summary.merge(prior_provider: counts.merge(paycheck_count: 60)) })
      expect(provider[:rows].map(&:first) - legacy_sheet_fields).to eq([
        "Prior-provider payrolls", "Prior-provider paychecks", "Prior-provider opening summaries",
        "Excluded unlinked prior-provider paychecks", "Excluded unlinked prior-provider gross pay", "Excluded unlinked prior-provider net pay"
      ])
      expect(provider[:rows].assoc("Prior-provider paychecks")).to eq([ "Prior-provider paychecks", 60 ])
      expect(provider[:rows] - provider[:rows].select { |row| row.first.to_s.match?(/prior-provider/i) }).to eq(legacy[:rows])
    end

    it "labels prior-provider pay runs and deduction columns by their source" do
      batch = ->(source) { double(source_system: source) }
      period = ->(id) { double(id: id, period_type: "regular", start_date: Date.new(2026, 1, id), end_date: Date.new(2026, 1, id + 1), pay_date: Date.new(2026, 1, id + 2)) }
      paychecks = [
        double(historical_pay_period: period.call(1), historical_pay_period_id: 1, historical_import_batch: batch.call("quickbooks_online")),
        double(historical_pay_period: period.call(5), historical_pay_period_id: 5, historical_import_batch: batch.call("prior_provider")),
        double(historical_pay_period: period.call(5), historical_pay_period_id: 5, historical_import_batch: batch.call("prior_provider"))
      ]
      allow(controller).to receive(:reportable_pay_periods).and_return(PayPeriod.none)
      runs = controller.send(:included_payroll_runs, nil, paychecks)
      expect(runs.map { |run| run.slice(:key, :source) }).to eq([
        { key: "imported:1", source: "QuickBooks import" }, { key: "imported:5", source: "Prior-provider history" }
      ])

      entry = ->(source, employee_id) { { employee_id: employee_id, source: source, treatment: "pre_tax_deduction", label: "401(k) pre-tax retirement", amount: BigDecimal("50") } }
      columns = controller.send(:period_summary_component_columns, [ entry.call("quickbooks", 1), entry.call("prior_provider", 2), entry.call("historical_adjustment", 3) ], [ 1, 2, 3 ])
      expect(columns.map { |column| column.slice(:label, :identity_label, :source_group) }).to contain_exactly(
        { label: "QuickBooks source - 401(k) pre-tax retirement (Pre tax deduction; QuickBooks source)", identity_label: "QuickBooks source", source_group: "quickbooks_history" },
        { label: "Prior-provider source - 401(k) pre-tax retirement (Pre tax deduction; Prior-provider source)", identity_label: "Prior-provider source", source_group: "prior_provider_history" },
        { label: "Historical adjustment - 401(k) pre-tax retirement (Pre tax deduction; Historical adjustment)", identity_label: "Historical adjustment", source_group: "historical_adjustment" }
      )
    end
  end
end
