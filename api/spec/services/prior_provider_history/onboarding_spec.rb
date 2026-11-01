# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Prior-provider existing-roster history" do
  include ActiveSupport::Testing::TimeHelpers

  before { ActiveJob::Base.queue_adapter = :test }

  around { |example| travel_to(Time.utc(2026, 11, 2, 2)) { example.run } }

  after do
    # Only this fixture's newly retained files, never shared application storage.
    HistoricalImportSourceFile.where(company: @company).find_each { |file| R2StorageService.new.delete(file.storage_key) } if @company
  end

  def fixture(period_count: 20)
    @company, @actor, @employees, @runs, @payload = history_fixture(period_count: period_count)
  end

  def no_payment_effects
    [ PayrollItem.where(company: @company).where.not(check_number: nil).count,
      @company.reload.next_check_number, PayrollLiabilityPosting.where(company: @company).count,
      NonEmployeeCheck.where(company: @company).count, LoanTransaction.count,
      Form500Filing.where(company: @company).count, PayrollFilingEvent.where(company: @company).count,
      EmployeeYtdTotal.where(employee_id: @company.employees.select(:id)).count, CompanyYtdTotal.where(company: @company).count,
      ActiveJob::Base.queue_adapter.enqueued_jobs.size ]
  end

  it "converts 20 paid semimonthly runs / 60 checks exactly once, activates normal YTD, reports all quarters and approves the first unpaid run" do
    fixture
    @payload["periods"].first["paychecks"].first["provider_payment_reference"] = "Provider check 1042 (already paid)"
    before = no_payment_effects
    onboarding = convert_history(@company, @actor, @payload, key: "complete-history-2026")
    expect(onboarding.historical_import_batch.historical_paychecks.count).to eq(60)
    reference = onboarding.historical_import_batch.historical_paychecks.find_by!(employee: @employees.first, pay_date: @runs.first.pay_date)
    expect(reference.source_metadata["provider_payment_reference"]).to eq("Provider check 1042 (already paid)")
    expect(reference.check_number).to be_nil
    expect(@runs.map { |run| run.reload.status }.uniq).to eq([ "retired_history" ])
    expect(@runs).to all(have_attributes(committed_at: nil, correction_status: nil))
    expect(@runs.first.can_edit?).to be(false)
    expect { @runs.first.update!(status: "approved") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { @runs.first.payroll_items.first.update!(gross_pay: 1) }.to raise_error(ActiveRecord::RecordNotSaved)
    expect { @runs.first.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(@employees.first.ytd_totals_before(year: 2026, pay_date: Date.new(2027, 1, 1), pay_period_id: 0)[:gross_pay]).to eq(0)
    expect(no_payment_effects).to eq(before)
    activate_history(onboarding, @actor)
    @employees.each do |employee|
      expect(employee.reload.ytd_totals_before(year: 2026, pay_date: Date.new(2027, 1, 1), pay_period_id: 0)).to include(gross_pay: 40_000, net_pay: 32_940, withholding_tax: 4_000)
      balance = HistoricalEmployeeYtdBalance.find_by!(company: @company, employee: employee)
      expect(balance).to have_attributes(social_security_taxable_wages: 40_000, medicare_taxable_wages: 40_000)
    end
    expect(no_payment_effects).to eq(before)
    expect(@company.payroll_filing_responsibilities.where(quarter: [ 1, 2, 3 ]).pluck(:responsible_party).uniq).to eq([ "external_provider" ])
    (1..3).each do |quarter|
      gate = PayrollFilingResponsibilityGate.quarterly(company: @company, tax_year: 2026, quarter: quarter)
      gate.fetch(:filings).each_value do |filing|
        expect(filing[:status]).to eq("external_provider_responsible")
        expect(filing.dig(:capabilities, :can_export_filing_ready)).to be(false)
      end
      packet = QuarterlyCompliancePacketBuilder.new(@company, 2026, quarter).generate
      expect(packet[:pay_periods].size).to eq(6)
      expect(packet[:form_500][:pay_periods]).to be_nil.or be_empty
    end
    expect(@company.payroll_filing_responsibilities.where(quarter: 4).pluck(:responsible_party).uniq).to eq([ "cornerstone" ])
    expect(@company.payroll_filing_responsibilities.find_by!(filing_type: "w2_gu")).to have_attributes(responsible_party: "cornerstone", imported_payroll_inclusion: "included")
    source = HistoricalPayrollFilingSource.new(@company)
    expect(source.records(range: Date.new(2026, 10, 1)..Date.new(2026, 12, 31)).sum(&:gross_pay)).to eq(12_000)
    annual = W2GuAggregator.new(@company, 2026).generate
    expect(annual[:employees].map { |row| row[:box1_wages_tips_other_comp] }).to eq([ 40_000, 40_000, 40_000 ])
    expect(annual[:totals][:box1_wages_tips_other_comp]).to eq(120_000)
    # Restore the real lifecycle for the genuinely unpaid run.
    period = create(:pay_period, company: @company, start_date: "2026-11-01", end_date: "2026-11-15", pay_date: "2026-11-18")
    @employees.each do |employee|
      item = create(:payroll_item, :salary, company: @company, employee: employee, pay_period: period, pay_rate: 48_000)
      item.calculate!
      expect(item.reload.ytd_gross).to eq(42_000)
      expect(item.tax_rule_snapshot.fetch("annual_fica_context")).to include("version" => EmployeeYearFicaContext::VERSION)
      expect(item.tax_rule_snapshot.fetch("annual_fica_context")).not_to have_key("mode")
    end
    period.update!(status: "calculated")
    PayPeriodLifecycleService.new(pay_period: period, actor: @actor).approve!
    expect(period.reload.status).to eq("approved")
    expect(no_payment_effects).to eq(before)
    PayPeriodLifecycleService.new(pay_period: period, actor: @actor).commit!
    q4 = QuarterlyCompliancePacketBuilder.new(@company, 2026, 4).generate
    expect(q4.dig(:swica, :totals, :total_wages).to_d).to eq(18_000)
    expect(W2GuAggregator.new(@company, 2026).generate.dig(:totals, :box1_wages_tips_other_comp)).to eq(126_000)
    expect(Form941GuAggregator.new(@company, 2026, 4).generate.to_json).to include("18000")
    expect(q4.to_json).to include("paid_before_cornerstone", "prior_provider")
    expect(source.records(range: Date.new(2026, 10, 1)..Date.new(2026, 12, 31)).sum(&:gross_pay) + period.payroll_items.sum(:gross_pay)).to eq(18_000)
    expect { reverse_history(onboarding, @actor) }.to raise_error(ArgumentError, /first live payroll commitment/)
  end

  it "rejects a mismatched provider register without retiring or creating history" do
    fixture(period_count: 1)
    @payload["periods"][0]["register_totals"]["gross_pay"] = "5999.99"
    plan = PriorProviderHistory::Plan.new(company: @company, payload: @payload).call
    expect(plan.errors.join).to include("mismatch")
    expect(HistoricalPaycheck.count).to eq(0)
    expect(@runs.first.reload).to be_calculated
  end

  it "rejects stale source evidence and duplicate conversion, and retries the same request idempotently" do
    fixture(period_count: 1)
    @runs.first.payroll_items.first.update!(net_pay: 1_646)
    expect(PriorProviderHistory::Plan.new(company: @company, payload: @payload).call.errors.join).to include("changed")
    @runs.first.payroll_items.first.update!(net_pay: 1_647)
    @payload["periods"][0]["source_digest"] = PriorProviderHistory::SourceAdapter.digest(@runs.first.reload)
    onboarding = convert_history(@company, @actor, @payload, key: "retry-request-2026")
    retry_plan_digest = onboarding.preview_digest
    retry_record = PriorProviderHistory::Conversion.new(company: @company, actor: @actor, payload: @payload, preview_digest: retry_plan_digest,
      idempotency_key: "retry-request-2026", files: [], acknowledgement: PriorProviderHistory::Conversion::ACKNOWLEDGEMENT).call
    expect(retry_record).to eq(onboarding)
    expect(HistoricalPaycheck.count).to eq(3)
    expect(PriorProviderHistory::Plan.new(company: @company, payload: @payload).call.errors.join).to include("already has historical payroll")
  end

  it "verifies existing-roster identity and tenant isolation" do
    fixture(period_count: 1)
    @payload["identities"][@employees.first.id.to_s]["ssn_last4"] = "0000"
    expect(PriorProviderHistory::Plan.new(company: @company, payload: @payload).call.errors.join).to include("Verify the provider name")
    other = create(:employee)
    @payload["periods"][0]["paychecks"][0]["employee_id"] = other.id
    expect(PriorProviderHistory::Plan.new(company: @company, payload: @payload).call.errors.join).to include("keep each source employee")
  end

  it "accepts manually entered periods under the same reconciliation and explicit wage-base contract" do
    fixture(period_count: 1)
    period = @payload["periods"].first
    period.delete("run_id")
    period.delete("source_digest")
    @runs.first.destroy!
    onboarding = convert_history(@company, @actor, @payload)
    activate_history(onboarding, @actor)
    expect(HistoricalEmployeeYtdBalance.where(company: @company).sum(:gross_pay)).to eq(6_000)
    expect(onboarding.evidence["source_run_ids"]).to eq([])
  end

  it "reverses activated history before live commitment, restoring source runs and prior filing ownership while retaining audit evidence" do
    fixture(period_count: 1)
    onboarding = convert_history(@company, @actor, @payload)
    activate_history(onboarding, @actor)
    reverse_history(onboarding, @actor)
    expect(onboarding.reload.status).to eq("reversed")
    expect(@runs.first.reload).to be_calculated
    expect(@runs.first.paid_prior_provider_source?).to be(true)
    lifecycle = PayPeriodLifecycleService.new(pay_period: @runs.first, actor: @actor)
    expect { lifecycle.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /already paid/)
    expect { lifecycle.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /already paid/)
    expect(HistoricalPaycheck.count).to eq(3)
    expect(HistoricalEmployeeYtdBalance.count).to eq(3)
    expect(HistoricalYtdBridge.last.status).to eq("reversed")
    expect(@employees.first.reload.ytd_totals_before(year: 2026, pay_date: Date.new(2027, 1, 1), pay_period_id: 0)[:gross_pay]).to eq(0)
    expect(HistoricalPayrollFilingSource.new(@company).annual_balances(2026)).to be_empty
    expect(@company.payroll_filing_responsibilities).to be_empty
    expect(AuditLog.where(action: "prior_provider_history#reverse", record_id: onboarding.id)).to exist
  end
  it "preserves explicit taxable bases for non-taxable earnings and pre-tax deductions instead of deriving wages from gross or rounded tax" do
    fixture(period_count: 1)
    period = @payload["periods"].first
    row = period["paychecks"].first
    row.merge!("non_taxable_pay" => "100.00", "pretax_deductions" => "100.00", "retirement" => "100.00",
      "fit_taxable_wages" => "1800.00", "social_security_taxable_wages" => "1900.00", "medicare_taxable_wages" => "1900.00",
      "federal_income_tax" => "100.00", "social_security_tax" => "117.80", "medicare_tax" => "27.55",
      "employer_social_security_tax" => "117.80", "employer_medicare_tax" => "27.55", "net_pay" => "1654.65",
      "pretax_deduction_breakdown" => [ { "label" => "401(k) pre-tax", "amount" => "100.00" } ])
    period["register_totals"] = PriorProviderHistory::Amounts.totals(period["paychecks"]).slice(*PriorProviderHistory::Amounts::REGISTER_FIELDS)
    onboarding = convert_history(@company, @actor, @payload)
    activate_history(onboarding, @actor)
    balance = HistoricalEmployeeYtdBalance.find_by!(employee: @employees.first)
    expect(balance).to have_attributes(gross_pay: 2000, fit_taxable_wages: 1800, social_security_taxable_wages: 1900, medicare_taxable_wages: 1900)
    w2 = W2GuAggregator.new(@company, 2026).generate[:employees].find { |record| record[:employee_id] == @employees.first.id }
    expect(w2).to include(box1_wages_tips_other_comp: 1800, box3_social_security_wages: 1900, box5_medicare_wages_tips: 1900)
    record = HistoricalPayrollFilingSource.new(@company).records(range: Date.new(2026, 1, 1)..Date.new(2026, 12, 31)).find { |record| record.employee_id == @employees.first.id }
    expect(record).to have_attributes(fit_taxable_wages: 1800, social_security_taxable_wages: 1900, medicare_taxable_wages: 1900)
  end

  it "blocks missing wage bases, duplicate employee/pay dates, reconciliation drift and missing source attachments" do
    fixture(period_count: 1)
    @payload["periods"].first["paychecks"].first["medicare_taxable_wages"] = ""
    expect(PriorProviderHistory::Plan.new(company: @company, payload: @payload).call.errors.join).to include("confirm zero explicitly")
    @payload["periods"].first["paychecks"].first["medicare_taxable_wages"] = "2000.0"
    digest = PriorProviderHistory::Plan.new(company: @company, payload: @payload).call.digest
    expect {
      PriorProviderHistory::Conversion.new(company: @company, actor: @actor, payload: @payload, preview_digest: digest,
        idempotency_key: "missing-files-2026", files: [], acknowledgement: PriorProviderHistory::Conversion::ACKNOWLEDGEMENT).call
    }.to raise_error(ArgumentError, /Attach the previous/)
    expect(@runs.first.reload).to be_calculated
    @payload["periods"] << @payload["periods"].first.deep_dup.merge("key" => "duplicate", "run_id" => nil)
    expect(PriorProviderHistory::Plan.new(company: @company, payload: @payload).call.errors.join).to include("duplicate paychecks")
    expect(HistoricalImportBatch.count).to eq(0)
  end

  it "blocks live payroll until activation and preserves a conversion when retained registers fail verification" do
    fixture(period_count: 1)
    onboarding = convert_history(@company, @actor, @payload)
    expect { create(:pay_period, company: @company, start_date: "2026-11-01", end_date: "2026-11-15", pay_date: "2026-11-18") }.to raise_error(ActiveRecord::RecordInvalid, /Activate or reverse/)
    source = onboarding.historical_import_batch.historical_import_source_files.first
    R2StorageService.new.upload(source.storage_key, "corrupt source", content_type: "text/csv")
    expect { activate_history(onboarding, @actor) }.to raise_error(ArgumentError, /Retained registers/)
    expect(onboarding.reload.status).to eq("converted")
    expect(HistoricalEmployeeYtdBalance.count).to eq(0)
    expect(@runs.first.reload.status).to eq("retired_history")
  end

  it "rejects reversal with downstream calculations or revised filing ownership" do
    fixture(period_count: 1)
    onboarding = convert_history(@company, @actor, @payload)
    activate_history(onboarding, @actor)
    live = create(:pay_period, company: @company, start_date: "2026-11-01", end_date: "2026-11-15", pay_date: "2026-11-18")
    expect { reverse_history(onboarding, @actor) }.to raise_error(ArgumentError, /Remove downstream/)
    live.destroy!
    @company.payroll_filing_responsibilities.first.update!(notes: "A new filing decision")
    expect { reverse_history(onboarding, @actor) }.to raise_error(ArgumentError, /Filing ownership changed/)
    expect(onboarding.reload.status).to eq("active")
  end
  it "prefills active pre-tax adjustments in the correct register bucket" do
    fixture(period_count: 1)
    item = @runs.first.payroll_items.first
    item.update!(payroll_adjustments: [ { "label" => "Pre-tax adjustment", "treatment" => "pre_tax_deduction", "amount" => 50, "active" => true } ], total_deductions: 403, net_pay: 1597)
    row = PriorProviderHistory::SourceAdapter.candidate(@runs.first.reload).fetch("paychecks").find { |check| check["employee_id"] == item.employee_id }
    expect(row).to include("pretax_deductions" => "50.0", "after_tax_deductions" => "0.0")
  end

  it "reports prior-provider source counts and explicit tips without inferring their labels" do
    fixture(period_count: 1)
    period = @payload["periods"].first
    row = period["paychecks"].first
    row.merge!("reported_tips" => "100.00", "tips_paid_out" => "25.00", "after_tax_deductions" => "25.00", "net_pay" => "1622.00",
      "after_tax_deduction_breakdown" => [ { "label" => "Paid distribution", "amount" => "25.00" } ])
    period["register_totals"] = PriorProviderHistory::Amounts.totals(period["paychecks"]).slice(*PriorProviderHistory::Amounts::REGISTER_FIELDS)
    onboarding = convert_history(@company, @actor, @payload)
    activate_history(onboarding, @actor)
    reporting = UnifiedPayrollReporting.new(company_id: @company.id, period: PayrollReportingPeriod.from_params({ year: 2026 }))
    checks = onboarding.historical_import_batch.historical_paychecks.to_a
    row = reporting.history_row(checks.find { |check| check.employee_id == @employees.first.id })
    expect(row).to include(reported_tips: 100.0, tips_paid_out: 25.0)
    summary = reporting.source_summary(native_items: [], historical_paychecks: checks)
    expect(summary.dig(:quickbooks, :paycheck_count)).to eq(0)
    expect(summary.dig(:prior_provider, :paycheck_count)).to eq(3)
    expect(summary[:source_statement]).to include("already paid")
    expect(reporting.add_historical_to_employee_row({}, checks)).to include(tips: 100.0, tips_paid_out: 25.0)
  end

end
