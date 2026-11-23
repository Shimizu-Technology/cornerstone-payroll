# frozen_string_literal: true

require "rails_helper"

RSpec.describe BelowThresholdFicaContext do
  include FicaHistoryHelpers

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
        social_security_taxable_tips: tips, additional_medicare_taxable_wages: 0, fit_taxable_wages: gross, cash_tips_reported: tips)
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
    expect(item.pay_period.compliance_warnings.join).to include(employee.full_name, "voided pay period ##{original.pay_period_id}", "filing review remains open")
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

  it "calculates over legacy paychecks without recorded bases when no void, reversal or disposition exists" do
    legacy = history
    history(legacy: false)
    source_review
    item = calculate(tips: 50)
    expect(item).to have_attributes(social_security_taxable_wages: 450.to_d, social_security_taxable_tips: 50.to_d,
      social_security_tax: 31.to_d, medicare_tax: "7.25".to_d, additional_medicare_tax: 0.to_d)
    evidence = context(item)
    expect(evidence).to include("mode" => "calculable_below_thresholds", "history_review_open" => true, "filing_review_open" => true)
    expect(evidence.fetch("note")).to include("legacy paycheck ##{legacy.id} has no verified FICA bases")
    expect(item.pay_period.annual_fica_review_note).to include(employee.full_name, "legacy paycheck ##{legacy.id}")
    lifecycle = PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    expect(item.pay_period.reload).to be_committed
    expect(item.reload).to have_attributes(social_security_tax: 31.to_d, medicare_tax: "7.25".to_d)
    expect(legacy.reload.social_security_taxable_wages).to be_nil
    # Recovery keeps planning a reviewed proof for the derivable legacy row.
    plan = inventory
    expect(plan[:employee_years].sole[:rows].find { |row| row[:payroll_item_id] == legacy.id }).to include(status: "recoverable")
    expect(PayrollFicaLegacyRecovery.new(company: company, year: 2026)
      .apply!(actor: create(:user, company: company, role: "org_admin"), review_reference: "Synthetic legacy proof review",
        expected_digest: plan[:plan_digest])).to include(applied_proofs: 1)
    # Once proven, the next check verifies on the ordinary annual path.
    expect(context(calculate)).not_to include("mode" => "calculable_below_thresholds")
  end

  [ nil, {}, { "version" => 3, "fingerprint" => nil }, { "version" => 3, "fingerprint" => "" } ].each do |stored|
    it "treats a legacy annual context of #{stored.inspect} as unverified" do
      legacy = history
      legacy.update_columns(tax_rule_snapshot: legacy.tax_rule_snapshot.to_h.merge("annual_fica_context" => stored))
      source_review
      expect(context(calculate).fetch("note")).to include("legacy paycheck ##{legacy.id} has no verified FICA bases")
    end
  end

  def resolve_history(subject_type, code)
    entries = PayrollHistoryReview::Detector.new(company: company, tax_year: 2026).call(apply: true).fetch(:items)
    item = entries.map(&:first).find { |entry| entry.subject_type == subject_type }
    PayrollHistoryReview::Resolution.new(company: company, tax_year: 2026,
      subject_key: PayrollHistoryReview::Subject.key_for(item).join("-"), user: actor, actor: AuditActor.for_user(actor))
      .resolve!(code: code, reference: "Synthetic review documentation", expected_digest: item.subject_digest).first
  end

  def checksum(item)
    PayrollReview::CalculationSnapshot.new(pay_period: item.pay_period.reload).call.fetch(:checksum)
  end

  it "drops a resolved void from new calculations while preserving all calculated amounts" do
    history(voided: true)
    source_review
    before = calculate(tips: 50)
    resolve_history("voided_pay_period", "void_replaced")

    after = calculate(tips: 50)
    expect(after.attributes.slice(*EmployeeYearFicaContext::LEDGER_FIELDS.drop(2)))
      .to eq(before.attributes.slice(*EmployeeYearFicaContext::LEDGER_FIELDS.drop(2)))
    expect(after.pay_period.annual_fica_review_note).to be_nil
    expect(context(after)).not_to have_key("mode")
  end

  it "names only open subjects when a void and legacy gap coexist" do
    original = history(voided: true)
    legacy = history
    source_review
    note = context(calculate).fetch("note")
    expect(note).to include("voided pay period ##{original.pay_period_id}", "legacy paycheck ##{legacy.id}")

    resolve_history("voided_pay_period", "void_replaced")
    note = context(calculate).fetch("note")
    expect(note).to include("legacy paycheck ##{legacy.id}")
    expect(note).not_to include("voided pay period")
  end

  it "keeps bounded amounts and commits a closed legacy gap after it is reopened" do
    history
    source_review
    before = calculate(tips: 50)
    gap = resolve_history("legacy_basis_gap", "legacy_basis_accepted")
    after = calculate(tips: 50)
    expect(after.attributes.slice(*EmployeeYearFicaContext::LEDGER_FIELDS.drop(2)))
      .to eq(before.attributes.slice(*EmployeeYearFicaContext::LEDGER_FIELDS.drop(2)))
    expect(context(after)).to include("mode" => "calculable_below_thresholds", "history_review_open" => false,
      "filing_review_open" => true, "note" => nil)
    expect(after.pay_period.annual_fica_review_note).to be_nil

    lifecycle = PayPeriodLifecycleService.new(pay_period: after.pay_period, actor: actor)
    lifecycle.approve!
    saved_checksum = checksum(after)
    PayrollHistoryReview::Resolution.new(company: company, tax_year: 2026,
      subject_key: PayrollHistoryReview::Subject.key_for(gap).join("-"), user: actor, actor: AuditActor.for_user(actor))
      .reopen!(reason: "Another statement needs review", expected_digest: gap.subject_digest)
    expect(checksum(after)).to eq(saved_checksum)
    expect { lifecycle.commit! }.to change { after.pay_period.reload.status }.from("approved").to("committed")
  end

  it "matches the complete accepted gap when the current committed paycheck is excluded from the bound" do
    earlier = history
    current = history(gross: 500)
    current.update_columns(cash_tips_reported: 0)
    source_review
    rules = PayrollFicaLegacyRecovery.new(company: company, year: 2026).verified_year_rules
    calculation = lambda do
      annual = EmployeeYearFicaContext.new(employee: employee, year: 2026, excluding_pay_period_id: current.pay_period_id)
      amounts = annual.increment(wages_delta: current.gross_pay, tips_delta: 0, rules: rules, current_item: current)
      [ amounts, annual.snapshot ]
    end
    original_amounts, original_snapshot = calculation.call
    expect(original_snapshot.fetch("note")).to include("legacy paycheck ##{earlier.id}")
    expect(original_snapshot.fetch("note")).not_to include("legacy paycheck ##{current.id}")

    resolve_history("legacy_basis_gap", "legacy_basis_accepted")

    amounts, snapshot = calculation.call
    expect(amounts).to eq(original_amounts)
    expect(snapshot).to eq(original_snapshot.merge("history_review_open" => false, "note" => nil))
  end

  it "approves and commits a pre-release saved note after the void is resolved, with the same client checksum" do
    original = history(voided: true)
    history
    source_review
    item = calculate
    stored = item.tax_rule_snapshot
    legacy_note = "Prior-period payroll history needs accountant review: voided pay period ##{original.pay_period_id}. " \
      "This paycheck's Social Security/Medicare is unaffected because the conservative annual wage bounds are within the limits. " \
      "Historical tax and filing review remains open."
    item.update_columns(tax_rule_snapshot: stored.merge("annual_fica_context" => stored.fetch("annual_fica_context").merge("note" => legacy_note)))
    original_checksum = checksum(item)
    resolve_history("voided_pay_period", "void_replaced")
    expect(checksum(item)).to eq(original_checksum)

    lifecycle = PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor)
    lifecycle.approve!
    expect { lifecycle.commit! }.to change { item.pay_period.reload.status }.from("approved").to("committed")
    expect(context(item).fetch("note")).to eq(legacy_note)
  end

  it "commits an approved run calculated before the review decision" do
    history(voided: true)
    source_review
    item = calculate
    lifecycle = PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor)
    lifecycle.approve!
    saved_checksum = checksum(item)
    resolve_history("voided_pay_period", "void_reissued")
    expect(checksum(item)).to eq(saved_checksum)
    expect { lifecycle.commit! }.to change { item.pay_period.reload.status }.from("approved").to("committed")
  end

  it "does not count uncommitted practice-workspace legacy rows that the bound cannot see" do
    legacy = history
    legacy.pay_period.update_columns(status: "approved")
    source_review
    allow_any_instance_of(Company).to receive(:test_workspace?).and_return(true) # rubocop:disable RSpec/AnyInstance
    expect(EmployeeYearFicaContext.reportable_items(employee: employee, year: 2026)).to include(legacy)
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /explicit reviewed annual reconciliation/)
  end

  it "still holds legacy paychecks without recorded bases when stored taxes contradict uncapped wages" do
    history.update_columns(social_security_tax: 1, employer_social_security_tax: 1)
    source_review
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /contradict uncapped wages/)
  end

  it "calculates with an unlinked financial void even when there are no surviving ledger rows" do
    history(voided: true)
    source_review
    item = calculate
    expect(context(item)["history_review_open"]).to be(true)
    expect(item.social_security_tax).to eq(31)
  end

  [ :reversal, :void ].each do |reason|
    it "retains a specific #{reason} note with identical FICA amounts on an already verified annual path" do
      baseline = calculate(tips: 50)
      fields = %w[social_security_tax employer_social_security_tax medicare_tax employer_medicare_tax additional_medicare_tax
        social_security_taxable_wages social_security_taxable_tips medicare_taxable_wages additional_medicare_taxable_wages]
      expected = baseline.attributes.slice(*fields)
      prior = history(legacy: false, voided: reason == :void)
      if reason == :reversal
        prior.update_columns(payroll_reversed_at: Time.current, payroll_reversed_by_id: actor.id, payroll_reversal_reason: "Synthetic financial reversal")
      end
      source_review
      item = calculate(tips: 50)
      expect(item.attributes.slice(*fields)).to eq(expected)
      evidence = context(item)
      expect(evidence).to include("history_review_open" => true, "filing_review_open" => true)
      detail = reason == :void ? "voided pay period ##{prior.pay_period_id}" : "reversed paycheck ##{prior.id}"
      expect(evidence.fetch("note")).to include(detail)
      expect(evidence.fetch("note")).not_to include("imported paycheck history")
      expect(item.pay_period.annual_fica_review_note).to include(employee.full_name, detail)
      lifecycle = PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor)
      lifecycle.approve!
      lifecycle.commit!
      expect(item.reload.attributes.slice(*fields)).to eq(expected)
    end
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

  it "treats a legacy null Additional Medicare tax as zero only with a complete bound and exact paired Medicare totals" do
    [ history(voided: true), history ].each { |row| row.update_columns(additional_medicare_tax: nil) }
    source_review
    item = calculate
    expect(item).to have_attributes(medicare_tax: "7.25".to_d, employer_medicare_tax: "7.25".to_d,
      additional_medicare_tax: 0.to_d, additional_medicare_taxable_wages: 0.to_d)
    expect(context(item)).to include("history_review_open" => true, "filing_review_open" => true)
    expect(PayrollItemFicaBasisProof.count).to eq(0)
  end

  it "holds a null historical Additional Medicare tax when saved Medicare totals do not exactly reconcile" do
    row = history(voided: true)
    row.update_columns(additional_medicare_tax: nil, medicare_tax: "14.51")
    history
    source_review
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /FICA taxes contradict/)
  end

  it "holds null historical Additional Medicare taxes when the conservative Medicare bound is over the threshold" do
    [ history(voided: true), history ].each { |row| row.update_columns(additional_medicare_tax: nil) }
    source_review(ss: 0, medicare: "197500.01")
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /threshold/)
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
  it "omits the paycheck-specific review note once the paycheck is reversed" do
    history(voided: true)
    history
    source_review
    item = calculate
    expect(item.pay_period.annual_fica_review_note).to be_present
    item.update_columns(payroll_reversed_at: Time.current, payroll_reversed_by_id: actor.id, payroll_reversal_reason: "Synthetic reversal for disclosure regression")
    expect(item.pay_period.annual_fica_review_note).to be_nil
  end
  it "names source-review payday coverage alongside inventory wage-bound capacity" do
    history(voided: true)
    history
    source_review(through: "2026-02-01")
    result = inventory.fetch(:employee_years).first
    expect(result[:status]).to eq("calculable_below_thresholds")
    expect(result[:rows].map { |row| row[:reason] }).to include(a_string_including("pay date is covered by the latest source review"))
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /source review/)
  end
end
