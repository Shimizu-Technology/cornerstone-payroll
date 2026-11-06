# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee-year FICA context" do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company), pay_rate: 15) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:original) { create(:pay_period, :committed, company: company) }

  def calculate(period, gross, tips: 0)
    item = period.payroll_items.build(employee: employee, company: company, employment_type: "hourly",
      pay_rate: 15, hours_worked: 0, bonus: gross.to_d - tips.to_d, reported_tips: tips)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    item
  end

  def post(item)
    employee.ytd_totals_for(2024).add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(item)
  end

  def later_period(status: "committed", pay_date: "2024-02-02")
    create(:pay_period, company: company, status: status, start_date: "2024-01-01",
      end_date: "2024-01-14", pay_date: pay_date)
  end

  def preview(bonus)
    IssueCorrectivePaycheckService.preview(original_pay_period: original, employee: employee, corrected_inputs: { bonus: bonus })
  end

  [
    [ 1000, 75, 75, 0 ], [ 1000, -75, -75, 0 ],
    [ 168550, 75, 50, 0 ], [ 168650, -75, -25, 0 ],
    [ 169600, -75, 0, 0 ], [ 169600, 75, 0, 0 ],
    [ 199950, 75, 0, 25 ], [ 200050, -75, 0, -50 ],
    [ 200050, 75, 0, 75 ], [ 200500, -75, 0, -75 ]
  ].each do |wages, delta, ss_base, additional_base|
    it "reconciles a #{delta} correction against #{wages} in real annual wages" do
      base = calculate(original, 900)
      post(base)
      later = calculate(later_period, wages - 900)
      post(later)
      before = preview(900 + delta)
      expect(before[:deltas]).to include(social_security_taxable_wages: ss_base.to_d,
        additional_medicare_taxable_wages: additional_base.to_d,
        additional_medicare_tax: (additional_base.to_d * "0.009".to_d).round(2))
      _, correction = IssueCorrectivePaycheckService.issue!(original_pay_period: original, employee: employee,
        corrected_inputs: { bonus: 900 + delta }, pay_date: Date.new(2024, 2, 9), reason: "Annual reconciliation",
        actor: actor, expected_review_digest: before[:meta][:review_digest])
      expect(correction.social_security_tax).to eq((ss_base.to_d * "0.062".to_d).round(2))
      expect(correction.employer_social_security_tax).to eq(correction.social_security_tax)
      expect(correction.employer_medicare_tax).to eq((delta.to_d * "0.0145".to_d).round(2))
      expect(correction.medicare_tax).to eq(correction.employer_medicare_tax + correction.additional_medicare_tax)
      expect(correction.net_pay).to eq(before[:deltas][:net_pay].to_d)
      entries = correction.pay_period.payroll_liability_postings.sole.entries
      expect(entries.where(category: "social_security_employee").sum(:amount)).to eq(correction.social_security_tax)
      expect(entries.where(category: "social_security_employer").sum(:amount)).to eq(correction.employer_social_security_tax)
      expect(entries.where(category: "additional_medicare_employee").sum(:amount)).to eq(correction.additional_medicare_tax)
      expect(entries.where(category: "medicare_employee").sum(:amount)).to eq(correction.medicare_tax - correction.additional_medicare_tax)
      expect(entries.where(category: "medicare_employer").sum(:amount)).to eq(correction.employer_medicare_tax)
      w2 = W2GuAggregator.new(company, 2024, include_historical: false).generate.fetch(:employees).sole
      expect(w2[:box3_social_security_wages].to_d).to eq([ (wages + delta).to_d, 168600.to_d ].min)
      expect(w2[:box4_social_security_tax_withheld].to_d).to eq(base.social_security_tax + later.social_security_tax + correction.social_security_tax)
      expect(w2[:box5_medicare_wages_tips].to_d).to eq(wages + delta)
      form = Form941GuAggregator.new(company, 2024, 1, include_historical: false).generate
      expect(form[:lines][:line5a_ss_wages].to_d).to eq(w2[:box3_social_security_wages].to_d)
      expect(form[:tax_detail][:ss_employee].to_d).to eq(w2[:box4_social_security_tax_withheld].to_d)
      expect(form[:tax_detail][:medicare_employee].to_d).to eq(w2[:box6_medicare_tax_withheld].to_d)
      expect(form[:tax_detail][:medicare_employer].to_d).to eq(base.employer_medicare_tax + later.employer_medicare_tax + correction.employer_medicare_tax)
      expect(form[:lines][:line5d_add_medicare_wages].to_d).to eq([ (wages + delta - 200000).to_d, 0.to_d ].max)
      expect(employee.ytd_totals_for(2024).reload.social_security_tax).to eq(base.social_security_tax + later.social_security_tax + correction.social_security_tax)
      company_ytd = CompanyYtdTotal.find_by!(company: company, year: 2024)
      expect(company_ytd.social_security_tax).to eq(employee.ytd_totals_for(2024).social_security_tax)
      expect(company_ytd.employer_social_security).to eq(base.employer_social_security_tax + later.employer_social_security_tax + correction.employer_social_security_tax)
    end
  end

  it "holds a prior-year correction with zero writes" do
    post(calculate(original, 900))
    counts = [ PayPeriod.count, PayrollItem.count, PayrollLiabilityPosting.count, CheckEvent.count ]
    expect {
      IssueCorrectivePaycheckService.issue!(original_pay_period: original, employee: employee,
        corrected_inputs: { bonus: 975 }, pay_date: Date.new(2025, 1, 10), reason: "Prior-year hold", actor: actor)
    }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /prior.year.*separately reviewed/i)
    expect([ PayPeriod.count, PayrollItem.count, PayrollLiabilityPosting.count, CheckEvent.count ]).to eq(counts)
  end

  it "rejects the second precomputed run at approval and commit until recalculated" do
    post(calculate(original, "168499.95"))
    first, second = 2.times.map { later_period(status: "calculated") }
    [ first, second ].each { |period| calculate(period, 75) }
    service = ->(period) { PayPeriodLifecycleService.new(pay_period: period, actor: actor) }
    service.call(first).approve!
    service.call(second).approve!
    service.call(first).commit!
    expect { service.call(second).commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate.*another payroll/)
    expect(second.reload.status).to eq("approved")
    service.call(second).unapprove!
    expect { service.call(second).approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate.*another payroll/)
    second.payroll_items.destroy_all
    calculate(second, 75)
    service.call(second).approve!
    service.call(second).commit!
    expect(employee.payroll_items.sum(:social_security_taxable_wages)).to eq(168600)
  end

  it "binds correction review to later annual events even when the tax delta stays unchanged" do
    post(calculate(original, 900))
    old = preview(975)
    post(calculate(later_period, 100))
    expect(preview(975)[:meta][:review_digest]).not_to eq(old[:meta][:review_digest])
    expect {
      IssueCorrectivePaycheckService.issue!(original_pay_period: original, employee: employee,
        corrected_inputs: { bonus: 975 }, pay_date: Date.new(2024, 2, 9), reason: "Stale", actor: actor,
        expected_review_digest: old[:meta][:review_digest])
    }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
  end

  it "uses later committed wages for a backdated ordinary run" do
    post(calculate(later_period, 200050))
    item = calculate(original, 75)
    expect(item.social_security_tax).to eq(0)
    expect(item.additional_medicare_tax).to eq("0.68".to_d)
  end
  it "holds cross-year preview using the same date guard as issue" do
    post(calculate(original, 900))
    expect {
      IssueCorrectivePaycheckService.preview(original_pay_period: original, employee: employee,
        corrected_inputs: { bonus: 975 }, pay_date: "2025-01-10")
    }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /separately reviewed/)
  end

  it "rejects a calculated row without annual ledger evidence" do
    period = later_period(status: "calculated")
    item = calculate(period, 75)
    item.update!(tax_rule_snapshot: {})
    expect {
      PayPeriodLifecycleService.new(pay_period: period, actor: actor).approve!
    }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate/)
  end

  it "uses same-day later supplemental wages, tips, repeated corrections and excludes a voided correction" do
    post(calculate(original, 900, tips: 100))
    later = later_period(pay_date: original.pay_date)
    later.update!(cycle: "supplemental", corrects_pay_period: original)
    post(calculate(later, 167650, tips: 100))
    inputs = { bonus: 825, reported_tips: 150 }
    first_preview = IssueCorrectivePaycheckService.preview(original_pay_period: original, employee: employee, corrected_inputs: inputs)
    expect(first_preview[:deltas]).to include(social_security_taxable_wages: 25.to_d, social_security_taxable_tips: 25.to_d)
    first_period, first = IssueCorrectivePaycheckService.issue!(original_pay_period: original, employee: employee,
      corrected_inputs: inputs, pay_date: original.pay_date, reason: "Same-day tips", actor: actor)
    expect(first.social_security_tax).to eq("3.10".to_d)
    second_inputs = { bonus: 850, reported_tips: 175 }
    _, second = IssueCorrectivePaycheckService.issue!(original_pay_period: original, employee: employee,
      corrected_inputs: second_inputs, pay_date: original.pay_date, reason: "Repeated tips", actor: actor)
    expect(second.social_security_tax).to eq(0)
    PayPeriodCorrectionService.void!(pay_period: first_period, actor: actor, reason: "Void the first correction")
    repair = IssueCorrectivePaycheckService.preview(original_pay_period: original, employee: employee, corrected_inputs: second_inputs)
    expect(repair[:deltas][:social_security_tax]).to eq("3.10".to_d)
    IssueCorrectivePaycheckService.issue!(original_pay_period: original, employee: employee,
      corrected_inputs: second_inputs, pay_date: original.pay_date, reason: "Reconcile after void", actor: actor,
      expected_review_digest: repair[:meta][:review_digest])
    ledger = EmployeeYearFicaContext.reportable_items(employee: employee, year: 2024)
    expect(ledger.sum(:social_security_taxable_wages) + ledger.sum(:social_security_taxable_tips)).to eq(168600)
    w2 = W2GuAggregator.new(company, 2024, include_historical: false).generate.fetch(:employees).sole
    form = Form941GuAggregator.new(company, 2024, 1, include_historical: false).generate
    expect(w2[:box7_social_security_tips].to_d).to eq(ledger.sum(:social_security_taxable_tips))
    expect(form[:lines][:line5b_ss_tips].to_d).to eq(w2[:box7_social_security_tips].to_d)
  end

  it "invalidates a prepared ordinary run when a later correction is issued or voided" do
    post(calculate(original, 900))
    run = later_period(status: "calculated")
    calculate(run, 75)
    period, = IssueCorrectivePaycheckService.issue!(original_pay_period: original, employee: employee,
      corrected_inputs: { bonus: 975 }, pay_date: original.pay_date, reason: "Annual event", actor: actor)
    expect { PayPeriodLifecycleService.new(pay_period: run, actor: actor).approve! }
      .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate/)
    run.payroll_items.destroy_all
    calculate(run, 75)
    PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Reverse event")
    expect { PayPeriodLifecycleService.new(pay_period: run, actor: actor).approve! }
      .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate/)
  end

  it "includes only applied historical opening balances in ordinary and corrective taxes and fingerprints" do
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    bootstrap = HistoricalClientBootstrap.create!(company: company, historical_import_batch: batch,
      status: "applied", plan_digest: "ctx-bootstrap", applied_at: Time.current, applied_by: actor)
    bridge = HistoricalYtdBridge.create!(company: company, historical_import_batch: batch,
      historical_client_bootstrap: bootstrap, status: "applied", plan_digest: "ctx-bridge",
      preview_summary: { "through_period_end" => "2023-12-31", "through_pay_date" => "2024-01-01" },
      applied_at: Time.current, applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT)
    HistoricalEmployeeYtdBalance.create!(historical_ytd_bridge: bridge, company: company, employee: employee,
      tax_year: 2024, through_period_end: "2023-12-31", through_pay_date: "2024-01-01",
      gross_pay: 200050, medicare_taxable_wages: 200050, reported_tips: 100,
      social_security_taxable_wages: 168500, social_security_taxable_tips: 100)
    base = calculate(original, 900)
    post(base)
    expect(base.social_security_tax).to eq(0)
    expect(base.additional_medicare_tax).to eq("8.10".to_d)
    expect(preview(975)[:deltas][:additional_medicare_tax]).to eq("0.68".to_d)
    fingerprint = EmployeeYearFicaContext.new(employee: employee, year: 2024).fingerprint
    bridge.update_columns(status: "previewed", applied_at: nil, applied_by_id: nil, apply_acknowledgement: nil)
    expect(EmployeeYearFicaContext.new(employee: employee, year: 2024).fingerprint).not_to eq(fingerprint)
  end
  it "holds already-over-cap history for a separately reviewed adjustment" do
    base = calculate(original, 168600)
    post(base)
    base.update_columns(social_security_taxable_wages: 168675)
    expect { preview(168675) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /already exceeds/)
    expect { calculate(later_period(status: "draft"), 75) }
      .to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /separately reviewed/)
  end
  it "records a reviewed wage-to-tip reclassification even when net tax and cash do not change" do
    post(calculate(original, 900))
    inputs = { bonus: 850, reported_tips: 50 }
    reviewed = IssueCorrectivePaycheckService.preview(original_pay_period: original, employee: employee, corrected_inputs: inputs)
    expect(reviewed[:deltas]).to include(gross_pay: 0, social_security_taxable_wages: -50.to_d,
      social_security_taxable_tips: 50.to_d, social_security_tax: 0)
    expect(reviewed[:meta][:is_zero_change]).to be(false)
    _, item = IssueCorrectivePaycheckService.issue!(original_pay_period: original, employee: employee,
      corrected_inputs: inputs, pay_date: original.pay_date, reason: "Review wage/tip buckets", actor: actor)
    expect(item.social_security_taxable_tips).to eq(50)
    expect(item.net_pay).to eq(0)
  end
end
