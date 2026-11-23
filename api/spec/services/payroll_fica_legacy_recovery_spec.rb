# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFicaLegacyRecovery do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:employee) { person }

  def person
    create(:employee, company: company, department: create(:department, company: company), pay_rate: 15)
  end

  def calculate(person, gross, tips: 0, status: "committed")
    period = create(:pay_period, company: company, status: status)
    item = period.payroll_items.build(employee: person, company: company, employment_type: "hourly", pay_rate: 15,
      hours_worked: 0, bonus: gross.to_d - tips.to_d, reported_tips: tips)
    PayrollCalculator.for(person, item).calculate
    item.save!
    item
  end

  def legacy!(item)
    item.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil,
      additional_medicare_taxable_wages: nil, additional_medicare_tax: nil, medicare_taxable_wages: nil,
      cash_tips_reported: nil, tax_rule_snapshot: {})
    item.reload
  end

  def service
    described_class.new(company: company, year: 2024)
  end

  def apply(plan = service.inventory)
    service.apply!(actor: actor, review_reference: "Reviewed synthetic pre-release FICA reconciliation",
      expected_digest: plan.fetch(:plan_digest))
  end

  it "inventories mixed legacy history deterministically without writes, then recovers only provable employee-years" do
    first = calculate(employee, 1000, tips: 100)
    second = calculate(employee, 250, tips: 25)
    [ first, second ].each do |item|
      employee.ytd_totals_for(2024).add_payroll_item!(item)
      CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(item)
      legacy!(item)
    end
    ambiguous = person
    wrong = legacy!(calculate(ambiguous, 1000))
    wrong.update_columns(social_security_tax: 61)
    signed_person = person
    original = calculate(signed_person, 900)
    signed = create(:payroll_item, company: company, employee: signed_person, pay_period: create(:pay_period, :committed, company: company),
      correction_for_payroll_item: original, gross_pay: -50, net_pay: -40, social_security_tax: -3.1, medicare_tax: -0.73)
    legacy!(original)
    historical = [ first, second, wrong, original, signed ].to_h { |item| [ item.id, item.reload.attributes ] }
    plan = nil
    expect { plan = service.inventory }.not_to change(PayrollItemFicaBasisProof, :count)
    expect(service.inventory).to eq(plan)
    expect(plan[:counts]).to include(recoverable: 2, held: 3)
    expect(plan[:employee_years].find { |entry| entry[:employee_id] == ambiguous.id }[:rows].sole[:reason]).to match(/tax/)
    expect(plan[:employee_years].find { |entry| entry[:employee_id] == signed_person.id }[:rows].map { |row| row[:reason] }.join).to match(/correction/)
    expect { apply(plan) }.to change(PayrollItemFicaBasisProof, :count).by(2)
    historical.each { |id, attributes| expect(PayrollItem.find(id).attributes).to eq(attributes) }
    proof = PayrollItemFicaBasisProof.find_by!(payroll_item: first)
    expect(proof).to have_attributes(created_by_id: actor.id, review_reference: "Reviewed synthetic pre-release FICA reconciliation")
    expect(proof.evidence.fetch("bases")).to include("social_security_taxable_wages" => "900.0", "social_security_taxable_tips" => "100.0")
    next_item = calculate(employee, 75, status: "calculated")
    lifecycle = PayPeriodLifecycleService.new(pay_period: next_item.pay_period, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    expect(next_item.reload.social_security_tax).to eq("4.65".to_d)
    expect(next_item.pay_period.reload).to be_committed
    expect(employee.ytd_totals_for(2024).reload.social_security_tax).to eq("82.15".to_d)
    annual = W2GuAggregator.new(company, 2024, include_historical: false).generate[:employees].find { |row| row[:employee_id] == employee.id }
    expect(annual[:box3_social_security_wages].to_d).to eq(1200)
    expect(annual[:box7_social_security_tips].to_d).to eq(125)
    expect(annual[:box4_social_security_tax_withheld].to_d).to eq("82.15".to_d)
    expect { calculate(ambiguous, 75, status: "draft") }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError)
    expect { apply }.not_to change(PayrollItemFicaBasisProof, :count)
  end

  it "requires an authorized actor, review reference and unchanged plan before an atomic apply" do
    legacy!(calculate(employee, 1000))
    plan = service.inventory
    expect { service.apply!(actor: actor, review_reference: "", expected_digest: plan[:plan_digest]) }.to raise_error(ArgumentError, /review reference/i)
    stranger = create(:user, company: create(:company), role: "admin")
    expect { service.apply!(actor: stranger, review_reference: "Reviewed recovery", expected_digest: plan[:plan_digest]) }.to raise_error(ArgumentError, /authorized/i)
    expect { service.apply!(actor: actor, review_reference: "Reviewed recovery", expected_digest: "0" * 64) }.to raise_error(ArgumentError, /inventory changed/i)
    expect(PayrollItemFicaBasisProof.count).to eq(0)
  end

  def save_fingerprint(item, version:)
    prior = EmployeeYearFicaContext.new(employee: item.employee, year: 2024, excluding_pay_period_id: item.pay_period_id)
    stored = prior.snapshot.merge("version" => version, "fingerprint" => prior.fingerprint_for(version))
    item.update_columns(tax_rule_snapshot: item.tax_rule_snapshot.merge("annual_fica_context" => stored))
  end

  def dependent_v2_history
    first = calculate(employee, 1000)
    later = calculate(employee, 170000)
    # Known wages and zero tips allow a proof for the first row even above the cap.
    first.update_columns(tax_rule_snapshot: {}, social_security_taxable_tips: nil)
    save_fingerprint(later, version: 2)
    later.update_columns(social_security_taxable_wages: nil)
    [ first, later ]
  end

  it "recovers v2-dependent bases regardless of the order in which classification receives rows" do
    first, later = dependent_v2_history
    plan = service.inventory
    expect(plan[:employee_years].sole).to include(status: "ready",
      rows: [ a_hash_including(status: "recoverable"), a_hash_including(status: "proven") ])
    reversed = service
    allow(reversed).to receive(:plan_employee).and_wrap_original do |method, employee, ledger, opening, history|
      method.call(employee, ledger.reverse, opening, history)
    end
    expect(reversed.inventory).to eq(plan)
    expect { apply(plan) }.to change(PayrollItemFicaBasisProof, :count).by(1)
    expect(PayrollItemFicaBasisProof.pluck(:payroll_item_id)).to eq([ first.id ])
    expect(later.reload.social_security_taxable_wages).to be_nil
    expect(calculate(employee, 75, status: "calculated").social_security_tax).to eq(0)
  end

  it "discards all candidates and restores dependent row labels when another row is held" do
    complete = calculate(employee, 500)
    first, later = dependent_v2_history
    complete.update_columns(tax_rule_snapshot: complete.tax_rule_snapshot.merge("social_security_rate" => "0.061"))
    # The first row now needs its own proof, while the dependent row cannot
    # derive a capped wage base. A contradictory complete row blocks both.
    plan = service.inventory
    entry = plan[:employee_years].sole
    expect(entry).to include(status: "held", reason: a_string_including("##{complete.id}", "Captured year rules"))
    expect(entry[:rows]).to match([
      a_hash_including(payroll_item_id: complete.id, status: "held"),
      a_hash_including(payroll_item_id: first.id, status: "held"),
      a_hash_including(payroll_item_id: later.id, status: "held")
    ])
    expect(entry[:rows].filter_map { |row| row[:proposed_bases] }).to be_empty
    expect { apply(plan) }.not_to change(PayrollItemFicaBasisProof, :count)
    complete.update_columns(tax_rule_snapshot: complete.tax_rule_snapshot.merge("social_security_rate" => "0.062"))
    expect(service.inventory[:employee_years].sole[:rows].last).to include(payroll_item_id: later.id, status: "proven")
  end

  it "refuses a proof that would change a later committed v3 fingerprint" do
    first = calculate(employee, 1000)
    later = calculate(employee, 500)
    legacy!(first)
    save_fingerprint(later, version: 3)
    snapshot = later.reload.tax_rule_snapshot
    plan = service.inventory
    expect(plan[:employee_years].sole).to include(status: "held", reason: a_string_including("Payroll item ##{later.id}", "lacks verified FICA bases"))
    expect { apply(plan) }.not_to change(PayrollItemFicaBasisProof, :count)
    expect(later.reload.tax_rule_snapshot).to eq(snapshot)
  end

  it "holds a complete paycheck with partial SS bases and discards proposed proofs for that employee" do
    legacy = calculate(employee, 250)
    partial = calculate(employee, 1000)
    legacy!(legacy)
    partial.update_columns(social_security_taxable_wages: 900, social_security_tax: "55.80", employer_social_security_tax: "55.80")
    plan = service.inventory
    entry = plan[:employee_years].sole
    expect(entry).to include(status: "held", reason: a_string_including("payroll item ##{partial.id}",
      "Annual Social Security bases need an explicit reviewed reconciliation beyond this check's wage/tip changes"))
    expect(entry[:rows].first).not_to have_key(:proposed_bases)
    expect { apply(plan) }.not_to change(PayrollItemFicaBasisProof, :count)
  end

  it "rolls back every proof if the fresh ordinary probe fails inside a caller's transaction" do
    first = legacy!(calculate(employee, 1000))
    other = person
    second = legacy!(calculate(other, 1000))
    plan = service.inventory
    allow(PayrollItemFicaBasisProof).to receive(:create!).and_wrap_original do |method, **attributes|
      method.call(**attributes).tap do |proof|
        if proof.payroll_item_id == second.id
          expect(PayrollItemFicaBasisProof.pluck(:payroll_item_id)).to contain_exactly(first.id, second.id)
          second.update_columns(social_security_tax: 61)
        end
      end
    end

    ApplicationRecord.transaction do
      expect { apply(plan) }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError,
        /employee ##{other.id}.*item ##{second.id}/i)
      expect(PayrollItemFicaBasisProof.count).to eq(0)
      expect(second.reload.social_security_tax).to eq(62)
    end
  end

  it "rolls back proofs when ordinary probes pass but fresh fingerprint verification fails" do
    first = calculate(employee, 1000)
    later = calculate(employee, 500)
    legacy!(first)
    save_fingerprint(later, version: 2)
    plan = service.inventory
    expect(plan[:employee_years].sole[:status]).to eq("ready")
    allow(PayrollItemFicaBasisProof).to receive(:create!).and_wrap_original do |method, **attributes|
      method.call(**attributes).tap do
        invalid = later.tax_rule_snapshot.deep_merge("annual_fica_context" => { "fingerprint" => "0" * 64 })
        later.update_columns(tax_rule_snapshot: invalid)
        context = EmployeeYearFicaContext.new(employee: employee, year: 2024)
        expect(context.recorded_increment(wages_delta: 1, tips_delta: 0, rules: tax_table_rule_snapshot)
          .fetch(:social_security_taxable_wages)).to eq(1)
      end
    end

    expect { apply(plan) }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError,
      /Employee ##{employee.id}.*Payroll item ##{later.id}/)
    expect(PayrollItemFicaBasisProof.count).to eq(0)
    expect(later.reload.tax_rule_snapshot.dig("annual_fica_context", "fingerprint")).not_to eq("0" * 64)
  end

  it "holds a complete row with corrupted tax even when there are no candidate proofs" do
    row = calculate(employee, 1000)
    row.update_columns(social_security_tax: 61)
    expect(service.inventory[:employee_years].sole).to include(status: "held",
      reason: a_string_including("Payroll item ##{row.id}", "taxes do not reconcile"))
  end

  it "holds a proof plan when an otherwise calculable ledger has a mismatched committed fingerprint" do
    first = calculate(employee, 1000)
    later = calculate(employee, 500)
    legacy!(first)
    # The later row has complete and reconciled bases, so the ordinary probe
    # can pass even though the fingerprint no longer describes the first row.
    plan = service.inventory
    expect(plan[:employee_years].sole).to include(status: "held",
      reason: a_string_including("Payroll item ##{later.id}", "lacks verified FICA bases"))
    expect { apply(plan) }.not_to change(PayrollItemFicaBasisProof, :count)
  end

  it "binds the normalized employee scope to the digest and applies only that employee's proofs" do
    first = legacy!(calculate(employee, 1000))
    second = legacy!(calculate(person, 1000))
    selected = service.inventory(employee_ids: [ employee.id.to_s, employee.id ])
    expect(selected[:employee_ids]).to eq([ employee.id ])
    expect(selected[:employee_years].pluck(:employee_id)).to eq([ employee.id ])
    expect(service.inventory(employee_ids: [])[:employee_years]).to be_empty
    expect { apply(selected) }.to raise_error(ArgumentError, /inventory changed/)

    second.update_columns(social_security_tax: 61)
    expect(service.inventory(employee_ids: [ employee.id ])).to eq(selected)
    expect do
      service.apply!(actor: actor, review_reference: "Scoped synthetic proof review", expected_digest: selected[:plan_digest],
        employee_ids: [ employee.id ])
    end.to change(PayrollItemFicaBasisProof, :count).by(1)
    expect(PayrollItemFicaBasisProof.pluck(:payroll_item_id)).to eq([ first.id ])
  end

  it "rejects foreign and nonexistent employee scopes for both entry points" do
    foreign = create(:employee)
    missing = Employee.maximum(:id) + 1
    [ foreign.id, missing ].each do |id|
      expect { service.inventory(employee_ids: [ id ]) }.to raise_error(ArgumentError, /must belong to the company/)
      expect do
        service.apply!(actor: actor, review_reference: "Scoped synthetic proof review", expected_digest: "0" * 64,
          employee_ids: [ id ])
      end.to raise_error(ArgumentError, /must belong to the company/)
    end
  end

  it "binds recovery proofs into annual approval fingerprints and rejects altered financial evidence" do
    item = legacy!(calculate(employee, 1000))
    before = EmployeeYearFicaContext.new(employee: employee, year: 2024).snapshot
    apply
    expect(EmployeeYearFicaContext.new(employee: employee, year: 2024).snapshot).not_to eq(before)
    pending = calculate(employee, 75, status: "calculated")
    lifecycle = PayPeriodLifecycleService.new(pay_period: pending.pay_period, actor: actor)
    lifecycle.approve!
    item.update_columns(gross_pay: 1001)
    expect { lifecycle.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Roll Back Approval/)
    expect { calculate(employee, 75, status: "draft") }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /reconciliation/)
    expect(service.inventory[:counts][:held]).to eq(1)
  end

  it "rejects changes to captured rule evidence after reviewed recovery and approval" do
    item = legacy!(calculate(employee, 1000))
    apply
    pending = calculate(employee, 75, status: "calculated")
    lifecycle = PayPeriodLifecycleService.new(pay_period: pending.pay_period, actor: actor)
    lifecycle.approve!
    item.update_columns(tax_rule_snapshot: { tax_year: 2024, social_security_rate: "0.061" })
    expect { lifecycle.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Roll Back Approval/)
    expect { calculate(employee, 75, status: "draft") }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /reconciliation/)
  end

  it "keeps reviewed proof records append-only at both model and database boundaries" do
    item = legacy!(calculate(employee, 1000))
    apply
    proof = PayrollItemFicaBasisProof.find_by!(payroll_item: item)
    expect { proof.update!(review_reference: "Changed review reference") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { proof.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { proof.update_columns(evidence: {}) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "holds capped, unverifiable-year and contradictory Medicare history instead of inverting rounded taxes" do
    first = calculate(employee, 100000)
    second = calculate(employee, 100000)
    [ first, second ].each { |item| legacy!(item) }
    bad_med = legacy!(calculate(person, 1000))
    bad_med.update_columns(employer_medicare_tax: 14)
    plan = service.inventory
    expect(plan[:counts]).to include(recoverable: 0, held: 3)
    expect(plan[:employee_years].flat_map { |group| group[:rows] }.map { |row| row[:reason] }.join).to match(/cap/)
    expect { apply(plan) }.not_to change(PayrollItemFicaBasisProof, :count)
    tax_table.destroy!
    expect(service.inventory[:employee_years].flat_map { |group| group[:rows] }.map { |row| row[:reason] }.join).to match(/year rules/)
  end
  it "retains an established per-row proof when a different paycheck is subsequently reversed" do
    first = calculate(employee, 1000)
    second = calculate(employee, 250)
    [ first, second ].each do |item|
      employee.ytd_totals_for(2024).add_payroll_item!(item)
      CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(item)
      PayrollLiabilityPostingService.post!(pay_period: item.pay_period, actor: actor)
      legacy!(item)
    end
    apply
    ReversePaycheckService.call(payroll_item: first, actor: actor, reason: "Reviewed reversal after proof recovery")
    next_item = calculate(employee, 75, status: "calculated")
    expect(next_item.social_security_tax).to eq("4.65".to_d)
    expect(EmployeeYearFicaContext.reportable_items(employee: employee, year: 2024)).not_to include(first)
    expect(service.inventory[:counts]).to include(proven: 1, held: 0)
  end

  it "requires a verified tax year independently of FICA proof recovery" do
    legacy!(calculate(employee, 1000))
    tax_table.update!(verification_status: "draft")
    expect(service.inventory[:counts]).to include(recoverable: 0, held: 1)
    expect { apply }.not_to change(PayrollItemFicaBasisProof, :count)
    expect { calculate(employee, 75, status: "draft") }.to raise_error(ArgumentError, /not been verified/)
  end

  it "rejects an inventory plan changed by another committed paycheck before writing any proof" do
    original = legacy!(calculate(employee, 1000))
    plan = service.inventory
    create(:payroll_item, company: company, employee: employee, pay_period: create(:pay_period, :committed, company: company),
      gross_pay: 75, net_pay: "69.26", social_security_taxable_wages: 75, social_security_taxable_tips: 0,
      medicare_taxable_wages: 75, additional_medicare_taxable_wages: 0,
      social_security_tax: "4.65", employer_social_security_tax: "4.65", medicare_tax: "1.09", employer_medicare_tax: "1.09")
    expect { apply(plan) }.to raise_error(ArgumentError, /inventory changed/)
    expect(PayrollItemFicaBasisProof.count).to eq(0)
    expect(original.reload.social_security_taxable_wages).to be_nil
  end

  it "rolls back a company-year proof application if any proof write fails" do
    items = [ calculate(employee, 1000), calculate(employee, 250) ]
    items.each { |item| legacy!(item) }
    calls = 0
    allow(PayrollItemFicaBasisProof).to receive(:create!).and_wrap_original do |method, *arguments|
      calls += 1
      raise "Synthetic second proof failure" if calls == 2
      method.call(*arguments)
    end
    expect { apply }.to raise_error(RuntimeError, /Synthetic second proof failure/)
    expect(PayrollItemFicaBasisProof.count).to eq(0)
    expect(items.map { |item| item.reload.social_security_taxable_wages }).to eq([ nil, nil ])
  end

  it "uses the verified 2026 rules for genuine pre-release history rather than a nearby year's cap" do
    create(:tax_table, tax_year: 2026, ss_wage_base: 184500)
    prior = create(:pay_period, :committed, company: company, start_date: "2026-01-01", end_date: "2026-01-14", pay_date: "2026-01-16")
    original = create(:payroll_item, company: company, employee: employee, pay_period: prior, hours_worked: 0,
      gross_pay: 1000, reported_tips: 100, net_pay: "923.50", social_security_tax: 62, employer_social_security_tax: 62,
      medicare_tax: "14.50", employer_medicare_tax: "14.50", tax_rule_snapshot: {})
    recovery = described_class.new(company: company, year: 2026)
    plan = recovery.inventory
    expect(plan[:counts]).to include(recoverable: 1, held: 0)
    recovery.apply!(actor: actor, review_reference: "Reviewed 2026 historical reconciliation", expected_digest: plan[:plan_digest])
    proof = PayrollItemFicaBasisProof.find_by!(payroll_item: original)
    expect(proof.evidence.fetch("rules").fetch("social_security_wage_base")).to eq("184500.0")
    current = create(:pay_period, company: company, status: "calculated", start_date: "2026-01-15", end_date: "2026-01-28", pay_date: "2026-01-30")
    item = current.payroll_items.build(employee: employee, company: company, employment_type: "hourly", pay_rate: 15, hours_worked: 5)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    lifecycle = PayPeriodLifecycleService.new(pay_period: current, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    expect(item.reload.social_security_tax).to eq("4.65".to_d)
    expect(original.reload.social_security_taxable_wages).to be_nil
  end

  it "loads populated reviewed-proof histories in two business SELECTs without full snapshots" do
    people = 4.times.map { person }
    periods = 26.times.map { create(:pay_period, :committed, company: company) }
    template = calculate(employee, 1000).attributes.except("id").merge("tax_rule_snapshot" => {},
      "social_security_taxable_wages" => nil, "social_security_taxable_tips" => nil,
      "additional_medicare_taxable_wages" => nil, "additional_medicare_tax" => nil,
      "calculation_context_snapshot" => { "unused" => "x" * 10000 })
    PayrollItem.insert_all!(people.flat_map { |person| periods.map { |period| template.merge("employee_id" => person.id, "pay_period_id" => period.id) } })
    expect { apply }.to change(PayrollItemFicaBasisProof, :count).by(104)
    queries = []
    contexts = nil
    capture = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].start_with?("SELECT") }
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        contexts = EmployeeYearFicaContext.batch(company: company, employees: people, year: 2024)
        contexts.each_value { |context| context.increment(wages_delta: 75, tips_delta: 0, rules: tax_table_rule_snapshot) }
      end
    end
    expect(queries.size).to eq(2)
    expect(queries.join).not_to include('"payroll_items".*', '"calculation_context_snapshot"')
  end

  it "holds known partial bases that contradict provably uncapped ordinary history" do
    item = legacy!(calculate(employee, 1000, tips: 100))
    item.update_columns(social_security_taxable_tips: 50, social_security_tax: "58.90", employer_social_security_tax: "58.90")
    other = legacy!(calculate(person, 1000))
    other.update_columns(additional_medicare_taxable_wages: 10, additional_medicare_tax: "0.09", medicare_tax: "14.59")
    plan = service.inventory
    expect(plan[:counts]).to include(recoverable: 0, held: 2)
    expect { apply(plan) }.not_to change(PayrollItemFicaBasisProof, :count)
  end

  def tax_table_rule_snapshot
    { "social_security_wage_base" => 168600, "social_security_rate" => "0.062", "medicare_rate" => "0.0145", "additional_medicare_rate" => "0.009" }
  end
  it "holds contradictory captured year rules even when rounded stored taxes happen to match current rules" do
    original = legacy!(calculate(employee, 1000))
    original.update_columns(tax_rule_snapshot: { tax_year: 2024, social_security_wage_base: 900,
      social_security_rate: "0.0688888889", medicare_rate: "0.0145", additional_medicare_rate: "0.009", additional_medicare_threshold: 200000 })
    plan = service.inventory
    expect(plan[:counts]).to include(recoverable: 0, held: 1)
    expect(plan[:employee_years].sole[:rows].sole[:reason]).to match(/captured.*rules/i)
    expect { apply(plan) }.not_to change(PayrollItemFicaBasisProof, :count)
  end
end
