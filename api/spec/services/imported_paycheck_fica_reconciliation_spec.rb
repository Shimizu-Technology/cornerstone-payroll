# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe ImportedPaycheckFicaReconciliation do
  let!(:tax_table) { create(:tax_table, tax_year: 2026, ss_wage_base: 184500) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:employee) { create(:employee, company: company, pay_rate: 15) }
  let(:batch) do
    # Match the existing-client cutover shape: native history predates import.
    period = create(:pay_period, company: company, status: "committed", start_date: "2026-02-01", end_date: "2026-02-14", pay_date: "2026-02-20")
    create(:payroll_item, company: company, employee: employee, pay_period: period,
      gross_pay: 1000, reported_tips: 0, social_security_tax: 62, employer_social_security_tax: 62,
      medicare_tax: "14.50", employer_medicare_tax: "14.50", additional_medicare_tax: 0)
    create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
  end

  def service
    described_class.new(company: company, year: 2026)
  end

  def review(person = employee, ss: 0, through: "2026-12-31")
    EmployeeYearFicaSourceReview.record!(employee: person, actor: actor, tax_year: 2026,
      through_pay_date: through, external_ss_wage_bound: ss, external_medicare_wage_bound: ss,
      review_reference: "Synthetic review of all employer and predecessor wage sources")
  end

  def imported(person = employee, gross: 1000, tips: 0, employer: true)
    period = HistoricalPayPeriod.create!(historical_import_batch: batch, company: company,
      external_key: SecureRandom.uuid, source_label: "Synthetic import", start_date: "2026-01-01",
      end_date: "2026-01-14", pay_date: "2026-01-16", paycheck_count: 1, totals: {})
    worker = create(:historical_worker, company: company, historical_import_batch: batch, employee: person, mapping_status: "exact_match")
    ss = (gross.to_d * "0.062".to_d).round(2)
    med = (gross.to_d * "0.0145".to_d).round(2)
    HistoricalPaycheck.create!(historical_import_batch: batch, historical_pay_period: period, historical_worker: worker,
      company: company, employee: person, external_key: SecureRandom.uuid, source_employee_name: "Synthetic worker",
      source_row_number: 1, reconciliation_status: "matched", period_start: period.start_date, period_end: period.end_date,
      pay_date: period.pay_date, gross_pay: gross, adjusted_gross: gross, social_security_tax: ss, medicare_tax: med,
      earnings_breakdown: [ { label: "Regular", amount: (gross.to_d - tips.to_d).to_s("F") }, { label: "PayTip", amount: tips.to_s } ],
      employee_tax_breakdown: [ { label: "SS", amount: ss.to_s("F") }, { label: "Med", amount: med.to_s("F") } ],
      employer_tax_breakdown: employer ? [ { label: "SS", amount: ss.to_s("F") }, { label: "Med", amount: med.to_s("F") } ] : [])
  end

  # Shift stored taxes by signed cents from the rule-computed amounts while
  # keeping employee summary and detail consistent.
  def shift!(row, **cents)
    gross = row.gross_pay.to_d
    ss = (gross * "0.062".to_d).round(2)
    med = (gross * "0.0145".to_d).round(2)
    amount = ->(base, key) { base + cents.fetch(key, 0).to_d / 100 }
    employee_ss, employee_med = amount.call(ss, :employee_social_security_tax), amount.call(med, :employee_medicare_tax)
    row.update_columns(social_security_tax: employee_ss, medicare_tax: employee_med,
      employee_tax_breakdown: [ { label: "SS", amount: employee_ss.to_s("F") }, { label: "Med", amount: employee_med.to_s("F") } ],
      employer_tax_breakdown: [ { label: "SS", amount: amount.call(ss, :employer_social_security_tax).to_s("F") },
        { label: "Med", amount: amount.call(med, :employer_medicare_tax).to_s("F") } ])
    row
  end

  def calculate(person = employee, status: "calculated")
    run = create(:pay_period, company: company, status: status, start_date: "2026-11-01", end_date: "2026-11-14", pay_date: "2026-11-20")
    item = run.payroll_items.build(employee: person, company: company, employment_type: "hourly", pay_rate: 15,
      hours_worked: 0, bonus: 450, reported_tips: 50)
    Company.transaction do
      Company.lock.find(company.id)
      PayPeriod.lock.find(run.id)
      PayrollCalculator.for(person, item).calculate
      item.save!
    end
    item
  end

  def apply(plan = service.inventory, **options)
    service.apply!(actor: actor, review_reference: "Reviewed synthetic imported FICA reconciliation",
      expected_digest: plan.fetch(:plan_digest), **options)
  end

  [ 0, 100 ].each do |tips|
    it "proves exact imported checks with #{tips} tips, preserves amounts, calculates, approves and commits with review open" do
      row = imported(tips: tips)
      original = row.attributes
      review
      plan = service.inventory
      expect(plan[:counts]).to include("recoverable" => 1)
      expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /reviewed FICA proof/)
      expect { apply(plan) }.to change(HistoricalPaycheckFicaBasisProof, :count).by(1)
      expect(row.reload.attributes).to eq(original)
      expect(service.inventory[:counts]).to include("proven" => 1, "held" => 0)
      expect { apply }.not_to change(HistoricalPaycheckFicaBasisProof, :count)
      proof = row.fica_basis_proof
      expect(proof).to have_attributes(created_by_id: actor.id, plan_digest: plan[:plan_digest])
      expect(proof.evidence["bases"]).to include("social_security_taxable_wages" => (1000.to_d - tips).to_s("F"), "social_security_taxable_tips" => tips.to_d.to_s("F"))
      item = calculate
      expect(item).to have_attributes(social_security_tax: 31.to_d, medicare_tax: "7.25".to_d)
      expect(item.tax_rule_snapshot["annual_fica_context"]).to include("mode" => "calculable_below_thresholds", "history_review_open" => true, "filing_review_open" => true)
      lifecycle = PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor)
      lifecycle.approve!
      lifecycle.commit!
      expect(item.pay_period.reload).to be_committed
      expect(PayrollFicaLegacyRecovery.new(company: company, year: 2026).inventory[:employee_year_counts]).not_to have_key("held")
    end
  end

  it "accepts absent employer components, and corroborates present ones within one cent" do
    row = imported(employer: false)
    review
    expect(service.inventory[:counts]["recoverable"]).to eq(1)
    expect(service.inventory[:employee_years].sole[:rows].sole[:residual_cents]).to eq("employee_social_security_tax" => 0, "employee_medicare_tax" => 0)
    row.update_columns(employer_tax_breakdown: [ { label: "SS", amount: "61.99" } ])
    expect(service.inventory[:employee_years].sole[:rows].sole).to include(status: "recoverable",
      residual_cents: { "employee_social_security_tax" => 0, "employee_medicare_tax" => 0, "employer_social_security_tax" => -1 })
    row.update_columns(employer_tax_breakdown: [ { label: "SS", amount: "61.98" } ])
    expect(service.inventory[:employee_years].sole[:rows].sole[:reason])
      .to include("employer social_security_tax differs from the rule-computed amount by -$0.02 (stored 61.98, computed 62.00)")
    row.update_columns(employer_tax_breakdown: [ { label: "SS", amount: "61.995" } ])
    expect(service.inventory[:employee_years].sole[:rows].sole[:reason]).to include("employer social_security_tax is not a whole-cent amount")
    expect(apply[:applied_proofs]).to eq(0)
  end

  ImportedPaycheckFicaEvidence::RESIDUAL_COMPONENTS.each do |component|
    [ 1, -1 ].each do |cents|
      it "accepts a #{cents.positive? ? "+" : "-"}$0.01 #{component} rounding residual, records it and derives bases from gross" do
        row = shift!(imported(tips: 100), component.to_sym => cents)
        original = row.reload.attributes
        review
        plan = service.inventory
        report = plan[:employee_years].sole[:rows].sole
        expected = ImportedPaycheckFicaEvidence::RESIDUAL_COMPONENTS.to_h { |key| [ key, key == component ? cents : 0 ] }
        expect(report).to include(status: "recoverable", residual_cents: expected)
        expect(plan[:employee_years].sole).to include(residual_totals_cents: expected, checks_with_residual: 1)
        expect(plan).to include(residual_totals_cents: expected, checks_with_residual: 1, corroboration_tolerance_cents: 1)
        expect(apply(plan)[:applied_proofs]).to eq(1)
        evidence = row.reload.fica_basis_proof.evidence
        expect(evidence).to include("version" => 2, "corroboration_tolerance_cents" => 1, "residual_cents" => expected)
        expect(evidence["bases"]).to eq("additional_medicare_taxable_wages" => "0.0", "medicare_taxable_wages" => "1000.0",
          "social_security_taxable_tips" => "100.0", "social_security_taxable_wages" => "900.0")
        expect(row.attributes).to eq(original)
        expect(service.inventory[:employee_years].sole[:rows].sole).to include(status: "proven", residual_cents: expected)
        expect(calculate).to have_attributes(social_security_tax: 31.to_d, medicare_tax: "7.25".to_d)
      end
    end

    it "holds a $0.02 #{component} difference with a reason naming the component and difference" do
      row = shift!(imported, component.to_sym => 2)
      review
      report = service.inventory[:employee_years].sole[:rows].sole
      party, field = component.split("_", 2)
      expect(report).to include(status: "held")
      expect(report).not_to have_key(:residual_cents)
      expect(report[:reason]).to include("#{party} #{field} differs from the rule-computed amount by +$0.02", "beyond the $0.01 per-check rounding tolerance")
      expect(apply[:applied_proofs]).to eq(0)
      expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /#{party} #{field} differs/)
      expect(row.reload.fica_basis_proof).to be_nil
    end
  end

  it "totals mixed residuals into a digest-covered plan and holds the employee-year when any check exceeds a cent" do
    rows = [ imported, shift!(imported, employee_social_security_tax: 1, employer_social_security_tax: 1),
      shift!(imported, employee_medicare_tax: -1, employer_medicare_tax: 1), shift!(imported, employee_social_security_tax: -1) ]
    review
    plan = service.inventory
    totals = { "employee_social_security_tax" => 0, "employee_medicare_tax" => -1, "employer_social_security_tax" => 1, "employer_medicare_tax" => 1 }
    expect(plan[:employee_years].sole).to include(status: "ready", residual_totals_cents: totals, checks_with_residual: 3)
    expect(plan[:plan_digest]).to eq(FicaBasisEvidence.digest(plan.except(:plan_digest)))
    shift!(rows.last, employee_social_security_tax: 1)
    changed = service.inventory
    expect(changed[:employee_years].sole[:residual_totals_cents]).to include("employee_social_security_tax" => 2)
    expect(changed[:plan_digest]).not_to eq(plan[:plan_digest])
    expect { apply(plan) }.to raise_error(ArgumentError, /inventory changed/)
    shift!(imported, employee_medicare_tax: -2)
    held = service.inventory
    expect(held[:counts]).to include("held" => 5, "recoverable" => 0)
    expect(held[:employee_years].sole).to include(status: "held", reason: /employee medicare_tax differs from the rule-computed amount by -\$0\.02/)
    expect(held[:employee_years].sole[:residual_totals_cents]).to eq(totals.merge("employee_social_security_tax" => 2))
    expect(apply(held)[:applied_proofs]).to eq(0)
  end

  it "rejects changed plan digests and reloads authorization under locks" do
    row = imported
    review
    plan = service.inventory
    row.update_columns(net_pay: 1)
    expect { apply(plan) }.to raise_error(ArgumentError, /inventory changed/)
    expect { apply(service.inventory, expected_digest: "0" * 64) }.to raise_error(ArgumentError, /inventory changed/)
    stranger = create(:user, company: create(:company), role: "admin")
    expect { apply(service.inventory, actor: stranger) }.to raise_error(ArgumentError, /authorized/)
    stale_actor = User.find(actor.id)
    actor.update_column(:active, false)
    expect { apply(service.inventory, actor: stale_actor) }.to raise_error(ArgumentError, /authorized/)
    expect(HistoricalPaycheckFicaBasisProof.count).to eq(0)
  end

  it "requires source coverage and conservative bounds including imports, later native rows and external wages" do
    calculate(status: "committed")
    imported
    expect(service.inventory[:employee_years].sole[:reason]).to include("source review")
    review(through: "2026-10-31")
    expect(service.inventory[:counts]["held"]).to eq(1)
    review(ss: 184000)
    expect(service.inventory[:employee_years].sole[:reason]).to include("threshold")
    review
    expect(service.inventory[:employee_years].sole[:conservative_history_bounds]).to eq("ss" => "2500.0", "medicare" => "2500.0")
  end

  it "stales approval when imported source amounts, mapping or proof rule evidence change" do
    row = imported(tips: 100)
    review
    apply
    item = calculate
    row.update_columns(net_pay: 1)
    expect { PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor).approve! }
      .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate/)
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /matching reviewed FICA proof/)
  end

  it "protects proofs from update, delete and truncate, including SQL bypass" do
    imported
    review
    apply
    proof = HistoricalPaycheckFicaBasisProof.first!
    [ -> { proof.update_columns(review_reference: "tampered") }, -> { proof.delete },
      -> { ApplicationRecord.connection.execute("TRUNCATE historical_paycheck_fica_basis_proofs") } ].each do |mutation|
      expect do
        ApplicationRecord.transaction(requires_new: true) { mutation.call }
      end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end

  it "keeps unmapped company imports held and blocks mapped employee completeness" do
    imported
    row = imported
    row.update_columns(employee_id: nil)
    review
    expect(service.inventory[:counts]["held"]).to eq(2)
    expect(apply[:applied_proofs]).to eq(0)
  end

  it "ends an Active-MoSa-shaped nine-employee fixture with no holds and approved later runs" do
    people = [ employee, *create_list(:employee, 8, company: company, pay_rate: 15) ]
    people.each do |person|
      calculate(person, status: "committed")
      3.times { |index| imported(person, tips: index * 50) }
      review(person)
    end
    expect(service.inventory[:counts]["recoverable"]).to eq(27)
    expect(apply[:applied_proofs]).to eq(27)
    people.each do |person|
      item = calculate(person)
      PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor).approve!
      expect(item.pay_period.reload).to be_approved
    end
    inventory = PayrollFicaLegacyRecovery.new(company: company, year: 2026).inventory
    expect(inventory[:employee_year_counts].fetch("held", 0)).to eq(0)
    expect(service.inventory[:counts]).to include("held" => 0, "proven" => 27)
  end

  it "clears an Active-MoSa-shaped fixture with one-cent QuickBooks rounding across employees" do
    people = [ employee, *create_list(:employee, 8, company: company, pay_rate: 15) ]
    pattern = [ {}, { employee_social_security_tax: 1, employer_social_security_tax: 1 }, { employee_medicare_tax: -1, employer_medicare_tax: -1 },
      { employee_social_security_tax: -1, employer_social_security_tax: -1, employee_medicare_tax: 1, employer_medicare_tax: 1 } ]
    people.each_with_index do |person, index|
      calculate(person, status: "committed")
      pattern.each_with_index { |cents, check| shift!(imported(person, gross: 900 + (check * 37), tips: check * 25), **(index.zero? ? {} : cents)) }
      review(person)
    end
    plan = service.inventory
    expect(plan[:counts]).to include("recoverable" => 36, "held" => 0)
    expect(plan[:checks_with_residual]).to eq(24)
    expect(plan[:residual_totals_cents]).to eq("employee_social_security_tax" => 0, "employer_social_security_tax" => 0,
      "employee_medicare_tax" => 0, "employer_medicare_tax" => 0)
    expect(plan[:employee_years].map { |entry| entry[:checks_with_residual] }).to eq([ 0, *[ 3 ] * 8 ])
    expect(apply(plan)[:applied_proofs]).to eq(36)
    people.each do |person|
      item = calculate(person)
      PayPeriodLifecycleService.new(pay_period: item.pay_period, actor: actor).approve!
      expect(item.pay_period.reload).to be_approved
      expect(item.tax_rule_snapshot["annual_fica_context"]).to include("mode" => "calculable_below_thresholds", "history_review_open" => true, "filing_review_open" => true)
    end
    expect(PayrollFicaLegacyRecovery.new(company: company, year: 2026).inventory[:employee_year_counts].fetch("held", 0)).to eq(0)
    expect(service.inventory[:counts]).to include("held" => 0, "proven" => 36)
    expect { apply }.not_to change(HistoricalPaycheckFicaBasisProof, :count)
  end

  it "keeps an already authoritative native annual calculation available when optional imported evidence is unavailable" do
    calculate(status: "committed")
    imported
    # The legacy fixture is explicitly reconciled through the native task.
    recovery = PayrollFicaLegacyRecovery.new(company: company, year: 2026)
    recovery.apply!(actor: actor, review_reference: "Synthetic reviewed native annual bases",
      expected_digest: recovery.inventory.fetch(:plan_digest))
    item = calculate
    expect(item.tax_rule_snapshot["annual_fica_context"]).not_to have_key("mode")
  end

  it "does not invert tax into a partial allocation at the cap, or clear an over-limit current check" do
    imported
    review(ss: 182500)
    expect(service.inventory[:counts]["recoverable"]).to eq(1)
    apply
    expect { calculate }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /threshold/)
    review(ss: 182501)
    expect(service.inventory[:counts]["held"]).to eq(0) # old proof stays proven, capacity is separately held
    expect(service.inventory[:employee_years].sole[:status]).to eq("held")
  end

  it "binds changed source-review identity and native-source details even when wage bounds are unchanged" do
    imported
    review
    plan = service.inventory
    review
    expect { apply(plan) }.to raise_error(ArgumentError, /inventory changed/)
    plan = service.inventory
    company.payroll_items.first.update_columns(net_pay: 5)
    expect { apply(plan) }.to raise_error(ArgumentError, /inventory changed/)
  end

  it "binds an explicit same-company employee selection and leaves other imports untouched" do
    imported
    other = create(:employee, company: company)
    imported(other).update_columns(social_security_tax: 0)
    review
    scoped = described_class.new(company: company, year: 2026, employee_ids: [ employee.id ])
    expect(scoped.inventory[:counts]).to include("recoverable" => 1, "held" => 0)
    expect(scoped.apply!(actor: actor, review_reference: "Reviewed selected synthetic employee", expected_digest: scoped.inventory[:plan_digest])[:applied_proofs]).to eq(1)
    expect(HistoricalPaycheckFicaBasisProof.joins(:historical_paycheck).where(historical_paychecks: { employee_id: other.id })).to be_empty
    stranger = create(:employee)
    expect { described_class.new(company: company, year: 2026, employee_ids: [ stranger.id ]) }.to raise_error(ArgumentError, /belong/)
  end

  it "preserves multiple earnings rates, retirement, Roth and loan amounts without subtracting them from FICA gross" do
    row = imported(tips: 100)
    row.update_columns(earnings_breakdown: [ { label: "Joint", amount: "600" }, { label: "Joint Kitchen", amount: "300" }, { label: "PayTip", amount: "100" } ],
      adjusted_gross: 950, pretax_deductions: 50, pretax_deduction_breakdown: [ { label: "401(k) pre-tax", amount: "50" } ],
      after_tax_deductions: 175, after_tax_deduction_breakdown: [ { label: "Roth 401(k)", amount: "25" }, { label: "Employee loan", amount: "150" } ], net_pay: "698.50")
    original = row.reload.attributes
    review
    expect(apply[:applied_proofs]).to eq(1)
    expect(row.reload.attributes).to eq(original)
    expect(row.fica_basis_proof.evidence["bases"]).to include("medicare_taxable_wages" => "1000.0", "social_security_taxable_wages" => "900.0")
  end

  [ { earnings_breakdown: [ { label: "Cash tips uncertain", amount: "1000" } ] },
    { earnings_breakdown: [ { label: "Regular", amount: "999" } ] },
    { employer_tax_breakdown: [ { label: "Additional Medicare", amount: "0.01" } ] },
    { pretax_deduction_breakdown: [ { label: "Section 125", amount: "50" } ] } ].each do |changes|
    it "holds ambiguous source detail #{changes.keys.join(',')} instead of guessing an allocation" do
      row = imported
      row.update_columns(changes)
      review
      expect(service.inventory[:counts]["held"]).to eq(1)
      expect(apply[:applied_proofs]).to eq(0)
    end
  end

  it "exposes a read-only default task and digest-locked administrator apply" do
    imported
    review
    load Rails.root.join("lib/tasks/fica_legacy.rake")
    Rake::Task.define_task(:environment)
    values = { "COMPANY_ID" => company.id.to_s, "TAX_YEAR" => "2026", "ACTOR_ID" => actor.id.to_s,
      "REVIEW_REFERENCE" => "Reviewed imported FICA task fixture", "PLAN_DIGEST" => service.inventory[:plan_digest] }
    previous = values.to_h { |key, _| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    task = Rake::Task["payroll:fica_legacy:reconcile_imports"]
    expect { expect { task.invoke }.to output(/recoverable/).to_stdout }.not_to change(HistoricalPaycheckFicaBasisProof, :count)
    task.reenable
    expect { expect { task.invoke("apply") }.to output(/applied_proofs/).to_stdout }.to change(HistoricalPaycheckFicaBasisProof, :count).by(1)
  ensure
    previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    task&.reenable
  end
end
