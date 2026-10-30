# frozen_string_literal: true

require "rails_helper"

RSpec.describe BelowThresholdFicaContext do
  let!(:tax_table) { create(:tax_table, tax_year: 2026, ss_wage_base: 184500) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company), pay_rate: 15) }
  let(:actor) { create(:user, company: company, role: "admin") }

  def period(status: "committed", **attrs)
    create(:pay_period, company: company, status: status, start_date: "2026-01-01", end_date: "2026-01-14", pay_date: "2026-01-16", **attrs)
  end

  def source_review(ss: 0, medicare: ss, through: "2026-12-31")
    EmployeeYearFicaSourceReview.record!(employee: employee, actor: actor, tax_year: 2026, through_pay_date: through,
      external_ss_wage_bound: ss, external_medicare_wage_bound: medicare,
      review_reference: "Synthetic complete same-employer and predecessor wage sources reviewed")
  end

  def history(gross: 1000, tips: 0, voided: false, legacy: true)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period, hours_worked: 0,
      gross_pay: gross, reported_tips: tips, net_pay: gross.to_d * "0.9235".to_d,
      social_security_tax: (gross.to_d * "0.062".to_d).round(2), employer_social_security_tax: (gross.to_d * "0.062".to_d).round(2),
      medicare_tax: (gross.to_d * "0.0145".to_d).round(2), employer_medicare_tax: (gross.to_d * "0.0145".to_d).round(2),
      additional_medicare_tax: 0)
    if !legacy
      item.update_columns(medicare_taxable_wages: gross, social_security_taxable_wages: gross.to_d - tips.to_d,
        social_security_taxable_tips: tips, additional_medicare_taxable_wages: 0, cash_tips_reported: tips)
    end
    item.pay_period.update_columns(correction_status: "voided") if voided
    item
  end

  def calculate(gross: 500, tips: 0, **attrs)
    run = period(status: "calculated", pay_date: "2026-11-15")
    item = run.payroll_items.build(employee: employee, company: company, employment_type: "hourly", pay_rate: 15,
      hours_worked: 0, bonus: gross.to_d - tips.to_d, reported_tips: tips, **attrs)
    Company.transaction do
      Company.lock.find(company.id)
      PayPeriod.lock.find(run.id)
      PayrollCalculator.for(employee, item).calculate
      item.save!
    end
    item
  end

  def context(item)
    item.reload.tax_rule_snapshot.fetch("annual_fica_context")
  end

  def inventory
    PayrollFicaLegacyRecovery.new(company: company, year: 2026).inventory
  end

  it "calculates a void/replacement chain and commits saved amounts without closing historical or filing review" do
    original = history(voided: true, tips: 100)
    replacement = history(tips: 100)
    source_review
    expect { @item = calculate(tips: 50) }.not_to change(PayrollItemFicaBasisProof, :count)
    item = @item
    expect(item).to have_attributes(social_security_taxable_wages: 450.to_d, social_security_taxable_tips: 50.to_d,
      social_security_tax: 31.to_d, employer_social_security_tax: 31.to_d,
      medicare_tax: "7.25".to_d, employer_medicare_tax: "7.25".to_d, additional_medicare_tax: 0.to_d, net_pay: "461.75".to_d)
    expect(context(item)).to include("mode" => "calculable_below_thresholds", "history_review_open" => true,
      "filing_review_open" => true, "bounds" => { "ss" => "2500.0", "medicare" => "2500.0" })
    expect(item.pay_period.compliance_warnings.join).to include("Prior-period void history", "filing review remains open")
    lifecycle = PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    expect(item.pay_period.reload).to be_committed
    expect(item.reload).to have_attributes(social_security_tax: 31.to_d, medicare_tax: "7.25".to_d, net_pay: "461.75".to_d)
    expect(context(item)).to include("history_review_open" => true, "filing_review_open" => true)
    expect([ original, replacement ].map { |row| row.reload.social_security_taxable_wages }).to eq([ nil, nil ])
    expect(inventory[:employee_years].sole).to include(status: "calculable_below_thresholds", history_review_open: true, filing_review_open: true)
    expect(inventory[:counts][:calculable_below_thresholds]).to eq(1)
    expect(PayrollItemFicaBasisProof.count).to eq(0)
  end

  it "calculates with an unlinked financial void even when there are no surviving ledger rows" do
    history(voided: true)
    source_review
    item = calculate
    expect(context(item)["history_review_open"]).to be(true)
    expect(item.social_security_tax).to eq(31)
  end

  it "counts a retired instrument's retained earned wages and disposed originals conservatively" do
    history(voided: true)
    retired = history(legacy: false)
    retired.update_columns(voided: true, voided_at: Time.current, void_reason: "Retired instrument; wages remain owed")
    expect(EmployeeYearFicaContext.reportable_items(employee: employee, year: 2026)).to include(retired)
    disposed = history(gross: 0)
    PayrollItemLegacyDisposition.create!(payroll_item: disposed, company: company, created_by: actor,
      reason: PayrollItemLegacyDisposition::REASON, evidence_digest: "a" * 64)
    source_review
    expect(context(calculate).fetch("bounds")["ss"]).to eq("2500.0")
  end

  [ [ 184500, 0, true ], [ 184500, "0.01", false ] ].each do |threshold, extra, allowed|
    it "#{allowed ? 'allows' : 'holds'} the SS bound at configured threshold plus #{extra}" do
      history(voided: true)
      history
      source_review(ss: threshold.to_d - 2500 + extra.to_d)
      if allowed
        expect(context(calculate).fetch("bounds")["ss"]).to eq("184500.0")
      else
        expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /threshold/)
      end
    end
  end

  [ [ 0, true ], [ "0.01", false ] ].each do |extra, allowed|
    it "#{allowed ? 'allows' : 'holds'} the Additional Medicare bound at threshold plus #{extra}" do
      history(voided: true)
      history
      source_review(ss: 0, medicare: 197500.to_d + extra.to_d)
      if allowed
        item = calculate
        expect(context(item).fetch("bounds")["medicare"]).to eq("200000.0")
        expect(item.additional_medicare_tax).to eq(0)
      else
        expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /threshold/)
      end
    end
  end

  it "holds without external/predecessor completeness, with expired review or Additional Medicare exposure" do
    history(voided: true)
    history
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /completeness/)
    source_review(through: "2026-10-31")
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /completeness/)
    source_review(medicare: 200000)
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /threshold/)
  end

  %i[social_security_tax employer_medicare_tax social_security_taxable_wages medicare_taxable_wages reported_tips].each do |field|
    it "holds contradictory historical #{field}, even on a financially voided row" do
      row = history(voided: true)
      history
      row.update_columns(cash_tips_reported: 0) if field == :reported_tips
      row.update_columns(field => 1)
      source_review
      expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /contradict/i)
    end
  end

  it "holds a current signed correction and tip reclassification" do
    row = history(voided: true)
    source_review
    helper = described_class.new(employee: employee, company: company, year: 2026)
    item = build(:payroll_item, employee: employee, company: company, pay_period: period(status: "calculated"),
      gross_pay: -50, cash_tips_reported: 0, correction_for_payroll_item: row)
    rules = PayrollFicaLegacyRecovery.new(company: company, year: 2026).verified_year_rules
    expect { helper.snapshot(current_item: item, rules: rules) }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /correction/)
    item.correction_for_payroll_item = nil
    item.gross_pay = 0
    item.cash_tips_reported = 50
    expect { helper.snapshot(current_item: item, rules: rules) }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /reclassification/)
  end

  %i[committed voided disposed current current_tax current_basis rules exclusion source_review].each do |change|
    [ :approve!, :commit! ].each do |operation|
      it "stales #{operation} when #{change} evidence changes after calculation" do
        voided = history(voided: true)
        committed = history
        disposed = history(gross: 0)
        PayrollItemLegacyDisposition.create!(payroll_item: disposed, company: company, created_by: actor,
          reason: PayrollItemLegacyDisposition::REASON, evidence_digest: "a" * 64)
        source_review
        item = calculate
        lifecycle = PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor)
        lifecycle.approve! if operation == :commit!
        case change
        when :committed then committed.update_columns(net_pay: 900)
        when :voided then voided.update_columns(net_pay: 900)
        when :disposed then disposed.update_columns(gross_pay: 1)
        when :current then item.update_columns(gross_pay: 501)
        when :current_tax then item.update_columns(social_security_tax: 30)
        when :current_basis then item.update_columns(social_security_taxable_wages: nil)
        when :rules then tax_table.update_columns(ss_wage_base: 184501)
        when :exclusion then voided.pay_period.update_columns(correction_status: nil)
        when :source_review then source_review(ss: 1)
        end
        expect { lifecycle.public_send(operation) }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate/)
      end
    end
  end

  def opening(gross:)
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    bootstrap = HistoricalClientBootstrap.create!(company: company, historical_import_batch: batch,
      status: "applied", plan_digest: "source-bootstrap", applied_at: Time.current, applied_by: actor)
    bridge = HistoricalYtdBridge.create!(company: company, historical_import_batch: batch,
      historical_client_bootstrap: bootstrap, status: "applied", plan_digest: "source-bridge",
      preview_summary: { "through_period_end" => "2025-12-31", "through_pay_date" => "2026-01-01" },
      applied_at: Time.current, applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT)
    HistoricalEmployeeYtdBalance.create!(historical_ytd_bridge: bridge, company: company, employee: employee,
      tax_year: 2026, through_period_end: "2025-12-31", through_pay_date: "2026-01-01",
      gross_pay: gross, medicare_taxable_wages: gross, reported_tips: 0,
      social_security_taxable_wages: gross, social_security_taxable_tips: 0,
      social_security_tax: (gross.to_d * "0.062".to_d).round(2), medicare_tax: (gross.to_d * "0.0145".to_d).round(2))
  end

  it "counts all applied opening/QB bridge balances, including overlaps, and holds when they cross the cap" do
    history(voided: true)
    history
    source_review
    opening(gross: 1000)
    expect(context(calculate).fetch("bounds")["ss"]).to eq("3500.0")
    opening(gross: 183000)
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /threshold/)
  end

  it "stales approval for a changed bridge balance or bridge exclusion" do
    history(voided: true)
    history
    source_review
    balance = opening(gross: 1000)
    item = calculate
    balance.update_columns(source_breakdown: { "changed" => "source" })
    expect { PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor).approve! }
      .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate/)
  end

  [ nil, BigDecimal("NaN") ].each do |value|
    it "holds missing or nonfinite history instead of coercing it to zero (#{value.inspect})" do
      row = history(voided: true)
      history
      source_review
      row.update_columns(gross_pay: value)
      expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /source amounts/)
    end
  end

  it "counts and fingerprints earlier same-employer W-2 identity records across classification transitions" do
    old = create(:employee, company: company, department: employee.department)
    contractor = create(:employee, company: company, department: employee.department, employment_type: "contractor", previous_employee: old)
    employee.update!(previous_employee: contractor)
    original = history(voided: true)
    original.update_columns(employee_id: old.id)
    history
    source_review
    item = calculate
    expect(context(item).fetch("bounds")["ss"]).to eq("2500.0")
    original.update_columns(net_pay: 900)
    expect { PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor).approve! }
      .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate/)
  end

  it "does not change contractor FICA in a company with disputed employee history" do
    history(voided: true)
    item = period(status: "calculated").payroll_items.build(employee: employee, company: company,
      employment_type: "contractor", pay_rate: 500, hours_worked: 0)
    PayrollCalculator.for(employee, item, employment_type: "contractor").calculate
    expect(item.social_security_tax).to eq(0)
    expect(item.medicare_tax).to eq(0)
    expect(item.tax_rule_snapshot["annual_fica_context"]).to be_nil
  end

  it "invalidates client review when a voided source changes" do
    voided = history(voided: true)
    history
    source_review
    item = calculate
    review_service = PayrollReview::RevisionService.new(pay_period: item.pay_period, actor: actor)
    package = review_service.issue!
    voided.update_columns(net_pay: 100)
    expect { review_service.verify_current_checksum!(package) }.to raise_error(PayrollReview::RevisionService::Error, /Recalculate/)
  end

  it "does not let source review create historical FICA proofs and requires authorized, explicit amounts" do
    history(voided: true)
    expect { source_review }.not_to change(PayrollItemFicaBasisProof, :count)
    stranger = create(:user, company: create(:company), role: "admin")
    expect { EmployeeYearFicaSourceReview.record!(employee: employee, actor: stranger, tax_year: 2026) }.to raise_error(ArgumentError, /authorized/)
    expect { source_review(ss: -1) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
