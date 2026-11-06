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
  it "holds legacy over-cap withholding instead of assuming it is capped" do
    original = calc(period("2024-01-19"), 168600)
    original.update_columns(gross_pay: 168675, medicare_taxable_wages: nil, social_security_taxable_wages: nil,
      social_security_taxable_tips: nil, social_security_tax: "10457.85", employer_social_security_tax: "10457.85")
    expect { calc(period("2024-02-02", status: "draft"), 75) }.to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError)
  end
  it "does not invent a negative tip base on an ordinary wage-only check" do
    calc(period("2024-03-29"), 168600, tips: 1000)
    item = calc(period("2024-04-12"), 1000)
    q2 = Form941GuAggregator.new(company, 2024, 2, include_historical: false).generate
    expect(q2[:lines][:line5a_ss_wages]).to eq(0)
    expect(q2[:lines][:line5b_ss_tips]).to eq(0)
    expect(item.social_security_taxable_wages).to eq(0)
    expect(item.social_security_taxable_tips).to eq(0)
  end
  it "keeps the original annual context stable between calculation and approval" do
    calc(period("2024-01-19"), 900)
    p = period("2024-02-02", status: "calculated")
    calc(p, 75)
    expect { PayPeriodLifecycleService.new(pay_period: p, actor: actor).approve! }.not_to raise_error
    expect { PayPeriodLifecycleService.new(pay_period: p, actor: actor).commit! }.not_to raise_error
  end
  it "releases SS headroom after a void while retaining legacy evidence" do
    original = calc(period("2024-01-19"), 1000)
    original.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil)
    last = calc(period("2024-02-02"), 167650)
    expect(last.social_security_taxable_wages).to eq(167600)
    c = IssueCorrectivePaycheckService.preview(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 925 })
    expect(c[:deltas][:social_security_taxable_wages]).to eq(-25)
  end
  it "reconciles remaining signed bases after void even with one legacy row" do
    original = calc(period("2024-01-19"), 1000)
    original.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil)
    later = calc(period("2024-02-02"), 167650)
    [ original, later ].each do |item|
      employee.ytd_totals_for(2024).add_payroll_item!(item)
      CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(item)
    end
    first_period, = IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 925 }, pay_date: "2024-02-09", reason: "First negative correction", actor: actor)
    IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 900 }, pay_date: "2024-02-16", reason: "Second negative correction", actor: actor)
    PayPeriodCorrectionService.void!(pay_period: first_period, actor: actor, reason: "Void first negative adjustment")
    following = calc(period("2024-02-23"), 75)
    expect(EmployeeYearFicaContext.reportable_items(employee: employee, year: 2024).sum(:social_security_tax)).to eq("10453.20".to_d)
    expect(original.reload.social_security_taxable_wages).to be_nil
    expect(following.social_security_tax).to eq("1.55".to_d)
  end
  it "batches annual fingerprint queries for a multi-employee review" do
    p = period("2024-02-02", status: "calculated")
    10.times do
      e = create(:employee, company: company, department: create(:department, company: company))
      create(:payroll_item, company: company, employee: e, pay_period: p)
    end
    queries = []
    ActiveRecord::Base.uncached do
      callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        PayrollReview::CalculationSnapshot.new(pay_period: p).call
      end
    end
    expect(queries.count { |q| q.include?('FROM "companies"') }).to be <= 1
    expect(queries.count { |q| q.include?('FROM "historical_employee_ytd_balances"') }).to eq(1)
    expect(queries.count { |q| q.include?('FROM "payroll_items"') }).to be <= 2
  end

  it "retains recorded Additional Medicare bases after a void with a legacy null row" do
    original = calc(period("2024-01-19"), 1000)
    original.update_columns(additional_medicare_taxable_wages: nil)
    later = calc(period("2024-02-02"), 199050)
    [ original, later ].each do |item|
      employee.ytd_totals_for(2024).add_payroll_item!(item)
      CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(item)
    end
    first_period, = IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 925 }, pay_date: "2024-02-09", reason: "First negative correction", actor: actor)
    IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 900 }, pay_date: "2024-02-16", reason: "Second negative correction", actor: actor)
    PayPeriodCorrectionService.void!(pay_period: first_period, actor: actor, reason: "Void first negative adjustment")
    following = calc(period("2024-02-23"), 75)
    expect(following.additional_medicare_taxable_wages).to eq(50)
    expect(following.additional_medicare_tax).to eq("0.45".to_d)
  end

  it "holds an ambiguous partial legacy SS base instead of guessing from rounded tax" do
    legacy = calc(period("2024-01-19"), 1000, tips: 100)
    legacy.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil,
      social_security_tax: 31, employer_social_security_tax: 31, tax_rule_snapshot: {})
    expect { calc(period("2024-02-02", status: "draft"), 75) }
      .to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /explicit reviewed annual reconciliation/)
    expect(legacy.reload.social_security_taxable_wages).to be_nil
  end

  it "holds a missing nonzero Additional Medicare base rather than inverting rounded withholding" do
    legacy = calc(period("2024-01-19"), 200075)
    legacy.update_columns(additional_medicare_taxable_wages: nil, additional_medicare_tax: "0.68", tax_rule_snapshot: {})
    expect { calc(period("2024-02-02", status: "draft"), 75) }
      .to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /explicit reviewed annual reconciliation/)
  end

  it "retains a known SS bucket when recovering a fully taxed legacy row" do
    legacy = calc(period("2024-01-19"), 1000, tips: 100)
    legacy.update_columns(social_security_taxable_tips: nil)
    following = calc(period("2024-02-02"), 75)
    expect(following.social_security_taxable_wages).to eq(75)
    expect(following.social_security_taxable_tips).to eq(0)
    expect(legacy.reload.social_security_taxable_wages).to eq(900)
    expect(legacy.social_security_taxable_tips).to be_nil
  end

  it "keeps the cap guard active for mixed legacy and over-cap known bases" do
    legacy = calc(period("2024-01-19"), 1000)
    legacy.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil)
    later = calc(period("2024-02-02"), 167650)
    later.update_columns(social_security_taxable_wages: 167675)
    expect { calc(period("2024-02-16", status: "draft"), 75) }
      .to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /already exceeds/)
  end

  it "tells an operator with a pre-release approved run to roll back approval, recalculate, review and approve" do
    pending = period("2024-02-02", status: "calculated")
    item = calc(pending, 75)
    service = PayPeriodLifecycleService.new(pay_period: pending, actor: actor)
    service.approve!
    item.update_columns(tax_rule_snapshot: item.tax_rule_snapshot.except("annual_fica_context"))
    expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Roll Back Approval.*recalculate.*review and approve/)
    expect(pending.reload.status).to eq("approved")
  end

  it "loads a populated year in two queries with deterministic fingerprints and no unused snapshots" do
    employees = 10.times.map { create(:employee, company: company, department: create(:department, company: company)) }
    employees.each do |person|
      26.times do
        create(:payroll_item, company: company, employee: person, pay_period: create(:pay_period, :committed, company: company),
          calculation_context_snapshot: { "unused" => "x" * 10000 })
      end
    end
    queries = []
    contexts = nil
    ActiveRecord::Base.uncached do
      capture = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].start_with?("SELECT") }
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        contexts = EmployeeYearFicaContext.batch(company: company, employees: employees, year: 2024)
        contexts.each_value(&:snapshot)
      end
    end
    expect(queries.size).to eq(2)
    expect(queries.join).not_to include('"payroll_items".*', '"calculation_context_snapshot"', '"source_breakdown"')
    reversed = EmployeeYearFicaContext.batch(company: company, employees: employees.reverse, year: 2024)
    expect(contexts.transform_values(&:snapshot)).to eq(reversed.transform_values(&:snapshot))
  end
  it "holds even full-tax legacy amounts without proof of the original annual context" do
    legacy = calc(period("2024-01-19"), 1000)
    legacy.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil, tax_rule_snapshot: {})
    expect { calc(period("2024-02-02", status: "draft"), 75) }
      .to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /explicit reviewed annual reconciliation/)
  end

  it "recovers a missing nonzero Additional Medicare base from proven context without tax inversion" do
    legacy = calc(period("2024-01-19"), 200075)
    legacy.update_columns(additional_medicare_taxable_wages: nil)
    following = calc(period("2024-02-02"), 75)
    expect(following.additional_medicare_taxable_wages).to eq(75)
    expect(following.additional_medicare_tax).to eq("0.68".to_d)
    expect(legacy.reload.additional_medicare_taxable_wages).to be_nil
  end

  it "verifies the original v1 no-opening fingerprint before recovering missing bases" do
    legacy = calc(period("2024-01-19"), 1000)
    proof = Digest::SHA256.hexdigest(JSON.generate([ 2024, employee.id, [], nil ]))
    snapshot = legacy.tax_rule_snapshot.merge("annual_fica_context" => { "year" => 2024, "employee_id" => employee.id, "fingerprint" => proof })
    legacy.update_columns(tax_rule_snapshot: snapshot, social_security_taxable_wages: nil, social_security_taxable_tips: nil)
    expect(calc(period("2024-02-02"), 75).social_security_tax).to eq("4.65".to_d)
  end

  it "holds missing signed correction allocations even with positive gross and a captured fingerprint" do
    original = calc(period("2024-01-19"), 900)
    _, correction = IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 975 }, pay_date: "2024-02-09", reason: "Signed adjustment", actor: actor)
    correction.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil)
    expect { calc(period("2024-02-16", status: "draft"), 75) }
      .to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /explicit reviewed annual reconciliation/)
  end

  it "holds a missing base when the recorded Additional Medicare tax is also missing" do
    legacy = calc(period("2024-01-19"), 1000)
    legacy.update_columns(additional_medicare_taxable_wages: nil, additional_medicare_tax: nil)
    expect { calc(period("2024-02-02", status: "draft"), 75) }
      .to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /explicit reviewed annual reconciliation/)
  end

  it "allocates partial headroom to Q2 wages without moving Q1 tips" do
    calc(period("2024-03-29"), 168550, tips: 1000)
    following = calc(period("2024-04-12"), 1000)
    expect(following.social_security_taxable_wages).to eq(50)
    expect(following.social_security_taxable_tips).to eq(0)
    q2 = Form941GuAggregator.new(company, 2024, 2, include_historical: false).generate
    expect(q2[:lines][:line5a_ss_wages]).to eq(50)
    expect(q2[:lines][:line5b_ss_tips]).to eq(0)
  end
  it "invalidates approval when the evidence used to recover a legacy base changes" do
    legacy = calc(period("2024-01-19"), 1000)
    legacy.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil)
    pending = period("2024-02-02", status: "calculated")
    calc(pending, 75)
    service = PayPeriodLifecycleService.new(pay_period: pending, actor: actor)
    service.approve!
    legacy.update_columns(tax_rule_snapshot: legacy.tax_rule_snapshot.except("annual_fica_context"))
    expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Recalculate/)
    expect(pending.reload.status).to eq("approved")
  end

  it "holds malformed legacy fingerprint evidence with a reviewed reconciliation message" do
    legacy = calc(period("2024-01-19"), 1000)
    legacy.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil,
      tax_rule_snapshot: { "annual_fica_context" => "unknown" })
    expect { calc(period("2024-02-02", status: "draft"), 75) }
      .to raise_error(EmployeeYearFicaContext::UnreconciledLedgerError, /explicit reviewed annual reconciliation/)
  end

  it "retains a later retired check in annual FICA context when correcting an earlier paycheck" do
    original = calc(period("2024-01-19"), 900)
    later = calc(period("2024-02-02"), 199150, tips: 100)
    [ original, later ].each do |item|
      employee.ytd_totals_for(2024).add_payroll_item!(item)
      CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(item)
    end
    company.assign_check_numbers!([ later ])
    later.reload
    before = EmployeeYearFicaContext.new(employee: employee, year: 2024).snapshot
    later.void!(user: actor, reason: "Retire lost instrument; earned payroll retained")
    expect(EmployeeYearFicaContext.new(employee: employee, year: 2024).snapshot).to eq(before)
    reviewed = IssueCorrectivePaycheckService.preview(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 975 }, pay_date: "2024-02-09")
    expect(reviewed[:deltas]).to include(social_security_taxable_wages: 0.to_d, social_security_taxable_tips: 0.to_d,
      social_security_tax: 0.to_d, additional_medicare_taxable_wages: 75.to_d, additional_medicare_tax: "0.68".to_d)
    _, correction = IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 975 }, pay_date: "2024-02-09", reason: "Correction after later check retirement", actor: actor,
      expected_review_digest: reviewed[:meta][:review_digest])
    expect(correction.net_pay).to eq(reviewed[:deltas][:net_pay].to_d)
    expect(correction.additional_medicare_tax).to eq("0.68".to_d)
    ledger = EmployeeYearFicaContext.reportable_items(employee: employee, year: 2024)
    expect(ledger.sum(:social_security_taxable_wages) + ledger.sum(:social_security_taxable_tips)).to eq(168600)
    expect(employee.ytd_totals_for(2024).reload.social_security_tax).to eq(ledger.sum(:social_security_tax))
    entries = correction.pay_period.payroll_liability_postings.sole.entries
    expect(entries.where(category: "additional_medicare_employee").sum(:amount)).to eq("0.68".to_d)
    w2 = W2GuAggregator.new(company, 2024, include_historical: false).generate.fetch(:employees).sole
    form = Form941GuAggregator.new(company, 2024, 1, include_historical: false).generate
    expect(w2[:box3_social_security_wages].to_d + w2[:box7_social_security_tips].to_d).to eq(168600)
    expect(w2[:box5_medicare_wages_tips].to_d).to eq(200125)
    expect(form[:lines][:line5a_ss_wages].to_d + form[:lines][:line5b_ss_tips].to_d).to eq(168600)
    expect(form[:lines][:line5d_add_medicare_wages].to_d).to eq(125)
  end

  it "retains a retired corrective check in the baseline for a repeated correction" do
    original = calc(period("2024-01-19"), 900)
    _, first = IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 975 }, pay_date: "2024-02-09", reason: "First signed adjustment", actor: actor)
    first.void!(user: actor, reason: "Retire corrective check; payroll retained")
    reviewed = IssueCorrectivePaycheckService.preview(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 1000 }, pay_date: "2024-02-16")
    expect(reviewed[:deltas]).to include(gross_pay: 25.to_d, social_security_taxable_wages: 25.to_d,
      social_security_tax: "1.55".to_d)
    _, second = IssueCorrectivePaycheckService.issue!(original_pay_period: original.pay_period, employee: employee,
      corrected_inputs: { bonus: 1000 }, pay_date: "2024-02-16", reason: "Continue retained signed baseline", actor: actor,
      expected_review_digest: reviewed[:meta][:review_digest])
    expect(second.gross_pay).to eq(25)
    expect(EmployeeYearFicaContext.reportable_items(employee: employee, year: 2024).sum(:medicare_taxable_wages)).to eq(1000)
  end
end
