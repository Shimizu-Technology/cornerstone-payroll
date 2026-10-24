# frozen_string_literal: true

require "rails_helper"
RSpec.describe "PR376 independent review edges" do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company), pay_rate: 15) }
  let(:actor) { create(:user, company: company, role: "admin") }
  def period(date, status: "committed")
    create(:pay_period, company: company, start_date: "2024-01-01", end_date: "2024-01-14", pay_date: date, status: status)
  end
  def calc(period, gross, tips: 0)
    item = period.payroll_items.build(employee: employee, company: company, employment_type: "hourly", pay_rate: 15,
      hours_worked: 0, bonus: gross.to_d - tips.to_d, reported_tips: tips)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    item
  end
  def post(item)
    employee.ytd_totals_for(2024).add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(item)
  end

  it "preserves retired payroll but excludes an actual reversal and refuses stale corrective issue" do
    original = calc(period("2024-01-19"), 1000)
    post(original)
    later = calc(period("2024-02-02"), 167550)
    post(later)
    company.assign_check_numbers!([ later ])
    later.reload
    before = EmployeeYearFicaContext.new(employee: employee, year: 2024).snapshot
    later.void!(user: actor, reason: "Retire lost paper instrument only")
    ctx = EmployeeYearFicaContext.new(employee: employee, year: 2024)
    expect(ctx.snapshot).to eq(before)
    expect(ctx.cumulative_wages).to eq(168550)
    expect(calc(period("2024-02-09", status: "draft"), 75).social_security_tax).to eq("3.10".to_d)
    stale = IssueCorrectivePaycheckService.new(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 1075 }, pay_date: "2024-02-16", reason: "Review before reversal", actor: actor)
    stale.preview
    ReversePaycheckService.call(payroll_item: original, actor: actor, reason: "Reverse incorrect earned payroll")
    ctx = EmployeeYearFicaContext.new(employee: employee, year: 2024)
    expect(ctx.cumulative_wages).to eq(167550)
    expect(ctx.snapshot).not_to eq(before)
    expect(EmployeeYearFicaContext.reportable_items(employee: employee, year: 2024).pluck(:id)).to eq([ later.id ])
    counts = [ PayPeriod.count, PayrollItem.count, PayrollLiabilityPosting.count ]
    expect { stale.issue! }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /financially reversed/)
    expect { IssueCorrectivePaycheckService.preview(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 1075 }) }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /financially reversed/)
    expect([ PayPeriod.count, PayrollItem.count, PayrollLiabilityPosting.count ]).to eq(counts)
  end

  it "measures the pre-release legacy hold for a routine sub-cap paycheck" do
    legacy = calc(period("2024-01-19"), 1000)
    legacy.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil,
      additional_medicare_taxable_wages: nil, tax_rule_snapshot: legacy.tax_rule_snapshot.except("annual_fica_context"))
    expect { calc(period("2024-02-02", status: "draft"), 75) }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError) { |e| puts "ROLLOUT HOLD #{e.message}" }
    expect(legacy.reload.social_security_tax).to eq(62)
    expect(legacy.social_security_taxable_wages).to be_nil
  end

  it "retains SS bucket consistency after a pure tip reduction above the annual cap" do
    original = calc(period("2024-03-29"), 168600, tips: 1000)
    post(original)
    later = calc(period("2024-04-12"), 1000)
    post(later)
    reviewed = IssueCorrectivePaycheckService.preview(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { reported_tips: 900 }, pay_date: "2024-04-19")
    _, correction = IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { reported_tips: 900 }, pay_date: "2024-04-19", reason: "Correct overstated Q1 cash tips", actor: actor,
      expected_review_digest: reviewed[:meta][:review_digest])
    w2 = W2GuAggregator.new(company, 2024, include_historical: false).generate.fetch(:employees).sole
    q2 = Form941GuAggregator.new(company, 2024, 2, include_historical: false).generate
    puts "TIP REDUCTION preview=#{reviewed[:deltas]} saved=#{correction.attributes.slice('gross_pay', 'cash_tips_reported', 'social_security_taxable_wages', 'social_security_taxable_tips')} W2=#{w2.slice(:box3_social_security_wages, :box7_social_security_tips, :box5_medicare_wages_tips)} Q2=#{q2[:lines]}"
    expect(reviewed[:deltas]).to include(social_security_taxable_wages: 100.to_d, social_security_taxable_tips: -100.to_d, social_security_tax: 0.to_d)
    expect(correction.reload).to have_attributes(cash_tips_reported: -100.to_d, social_security_taxable_wages: 100.to_d,
      social_security_taxable_tips: -100.to_d, social_security_tax: 0.to_d, employer_social_security_tax: 0.to_d)
    expect(correction.net_pay).to eq(reviewed[:deltas][:net_pay].to_d)
    expect(w2[:box7_social_security_tips].to_d).to eq(900.to_d)
    expect(w2[:box3_social_security_wages].to_d).to eq(167700.to_d)
    expect(q2[:lines][:line5a_ss_wages].to_d).to eq(100.to_d)
    expect(q2[:lines][:line5b_ss_tips].to_d).to eq(-100.to_d)
    again = IssueCorrectivePaycheckService.preview(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { reported_tips: 800 }, pay_date: "2024-04-26")
    _, repeated = IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { reported_tips: 800 }, pay_date: "2024-04-26", reason: "Repeated reviewed tip correction", actor: actor,
      expected_review_digest: again[:meta][:review_digest])
    expect(repeated.reload).to have_attributes(social_security_taxable_wages: 100.to_d, social_security_taxable_tips: -100.to_d,
      social_security_tax: 0.to_d, employer_social_security_tax: 0.to_d)
    expect(repeated.net_pay).to eq(again[:deltas][:net_pay].to_d)
    entries = repeated.pay_period.payroll_liability_postings.sole.entries
    expect(entries.where(category: "social_security_employee").sum(:amount)).to eq(0)
    expect(entries.where(category: "social_security_employer").sum(:amount)).to eq(0)
    annual = W2GuAggregator.new(company, 2024, include_historical: false).generate.fetch(:employees).sole
    quarter = Form941GuAggregator.new(company, 2024, 2, include_historical: false).generate
    expect(annual[:box7_social_security_tips].to_d).to eq(800.to_d)
    expect(annual[:box3_social_security_wages].to_d).to eq(167800.to_d)
    expect(quarter[:lines][:line5a_ss_wages].to_d).to eq(200.to_d)
    expect(quarter[:lines][:line5b_ss_tips].to_d).to eq(-200.to_d)
  end

  [ 10, 100 ].each do |count|
    it "measures populated snapshot and batch query counts for #{count} employees" do
      people = count.times.map { create(:employee, company: company, department: create(:department, company: company)) }
      history = 26.times.map { period("2024-01-19") }
      pending = period("2024-02-02", status: "calculated")
      template = calc(history.first, 1000).attributes.except("id")
      template["calculation_context_snapshot"] = { "unused" => "x" * 10000 }
      rows = people.flat_map { |person| history.map { |h| template.merge("employee_id"=>person.id, "pay_period_id"=>h.id) } }
      PayrollItem.insert_all!(rows)
      PayrollItem.insert_all!(people.map { |person| template.merge("employee_id"=>person.id, "pay_period_id"=>pending.id) })
      queries = []
      batch = nil
      capture = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].start_with?("SELECT") }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
          batch = EmployeeYearFicaContext.batch(company: company, employees: people, year: 2024)
          batch.each_value(&:snapshot)
        end
      end
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC)-started)*1000).round(2)
      puts "BATCH count=#{count} history=#{count*26} selects=#{queries.size} ms=#{ms}"
      expect(queries.size).to eq(2)
      expect(queries.join).not_to include('"payroll_items".*', '"calculation_context_snapshot"', '"source_breakdown"')
      expect(batch.values.first.cumulative_wages).to eq(26000)
      reverse = EmployeeYearFicaContext.batch(company: company, employees: people.reverse, year: 2024)
      expect(batch.transform_values(&:snapshot)).to eq(reverse.transform_values(&:snapshot))
      one = EmployeeYearFicaContext.new(employee: people.first, company: company, year: 2024)
      expect(one.snapshot).to eq(batch.fetch(people.first.id).snapshot)
      queries.clear
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { PayrollReview::CalculationSnapshot.new(pay_period: pending).call }
      end
      puts "SNAPSHOT count=#{count} companies=#{queries.count { |q| q.include?('FROM "companies"') }} openings=#{queries.count { |q| q.include?('FROM "historical_employee_ytd_balances"') }} payroll=#{queries.count { |q| q.include?('FROM "payroll_items"') }} total=#{queries.size}"
      expect(queries.count { |q| q.include?('FROM "historical_employee_ytd_balances"') }).to eq(1)
      expect(queries.count { |q| q.include?('FROM "payroll_items"') }).to eq(2)
    end
  end
end
