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
