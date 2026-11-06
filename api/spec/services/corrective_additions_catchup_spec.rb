# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PR381 proved additions catch-up probe" do
  include_context "corrective payroll ledger fixtures"

  it "permits a reducing correction with already proved additions-limit catch-up" do
    employee.update!(retirement_rate: 0.05, employer_retirement_match_rate: 0.69, date_of_birth: Date.new(1970, 1, 1))
    verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
    original=original!(bonus: 99100)
    expect(original.gross_pay).to eq(100000)
    expect(original.retirement_payment).to eq(5000)
    expect(original.employer_retirement_match).to eq(69000)
    expect(original.retirement_rule_snapshot.dig("annual_additions", "current_catch_up")).to eq("5000.0")
    correction=issue(bonus: 98100)
    expect(correction.retirement_payment).to eq(-50)
    expect(correction.employer_retirement_match).to eq(-690)
  end

  [ :first, :second ].each do |voided|
    it "reconciles signed additions catch-up after repeated corrections, void #{voided}, repair and following payroll" do
      employee.update!(retirement_rate: 0.05, employer_retirement_match_rate: 0.69, date_of_birth: Date.new(1970, 1, 1))
      verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
      original = original!(bonus: 97100)
      frozen = freeze_history(original)
      expect(PayrollRetirementCatchUp.for_item(original)).to eq(3520)
      first = issue(bonus: 98100)
      second = issue(bonus: 96100)
      expect([ PayrollRetirementCatchUp.for_item(first), PayrollRetirementCatchUp.for_item(second) ]).to eq([ 740, -1480 ])
      expect(first.retirement_rule_snapshot.dig("annual_additions", "current_catch_up").to_d).to eq(4260)
      expect(second.retirement_rule_snapshot.dig("annual_additions", "current_catch_up").to_d).to eq(2780)
      stale = preview(bonus: 95100).dig(:meta, :review_digest)
      removed, retained = voided == :first ? [ first, second ] : [ second, first ]
      PayPeriodCorrectionService.void!(pay_period: removed.pay_period, actor: actor, reason: "Reverse catch-up classification delta")
      expect { issue({ bonus: 95100 }, digest: stale) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
      repair = issue(bonus: 96100)
      expect([ original, retained, repair ].sum { |item| PayrollRetirementCatchUp.for_item(item) }).to eq(2780)
      expect(employee.ytd_totals_for(2024).reload.retirement).to eq(4850)
      expect(company.payroll_liability_entries.where(category: "retirement_employer").sum(:amount)).to eq(66930)
      employee.update!(employer_retirement_match_rate: 0)
      verify_synthetic_retirement_plan!(employee, Date.new(2024, 2, 2), catch_up_enabled: true)
      following_period = create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 28), pay_date: Date.new(2024, 2, 2))
      following = following_period.payroll_items.build(company: company, employee: employee, employment_type: "hourly", pay_rate: 15, hours_worked: 0, bonus: 1000)
      PayrollCalculator.for(employee, following).calculate
      following.save!
      expect(following.retirement_rule_snapshot.dig("annual_additions", "prior_catch_up").to_d).to eq(2780)
      expect(PayrollRetirementCatchUp.for_item(following)).to eq(50)
      expect(freeze_history(original.reload)).to eq(frozen)
      [ first, second, repair, following ].each { |item| assert_cash(item) }
    end
  end

  it "holds active catch-up corrections without a signed classification proof" do
    employee.update!(retirement_rate: 0.05, employer_retirement_match_rate: 0.69, date_of_birth: Date.new(1970, 1, 1))
    verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
    original!
    correction = issue(bonus: 98100)
    context = correction.calculation_context_snapshot.deep_dup
    context.fetch("corrective_paycheck").delete("catch_up_ledger_version")
    correction.update_columns(calculation_context_snapshot: context)
    expect { preview(bonus: 97100) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /signed catch-up classification/)
    expect { issue(bonus: 97100) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    expect(period.supplemental_pay_periods.count).to eq(1)
  end
  [ [ "catch_up_ledger_version", nil ], [ "catch_up_classification_delta", nil ], [ "catch_up_classification_delta", "not-money" ] ].each do |key, value|
    it "holds unproved zero targets after a positive catch-up correction: #{key}=#{value.inspect}" do
      employee.update!(retirement_rate: 0.05, employer_retirement_match_rate: 0.69, date_of_birth: Date.new(1970, 1, 1))
      verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
      original = original!
      first = issue(bonus: 98100)
      reversal = issue(bonus: 0)
      expect(PayrollRetirementCatchUp.for_item(original)).to eq(0)
      expect(PayrollRetirementCatchUp.for_item(first)).to eq(4260)
      expect(PayrollRetirementCatchUp.for_item(reversal)).to eq(-4260)
      expect(reversal.retirement_rule_snapshot.dig("annual_additions", "current_catch_up").to_d).to eq(0)
      context = reversal.calculation_context_snapshot.deep_dup
      proof = context.fetch("corrective_paycheck")
      value.nil? ? proof.delete(key) : proof[key] = value
      reversal.update_columns(calculation_context_snapshot: context)
      expect { preview(hours_worked: 55, bonus: 0) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /signed catch-up classification/)
      expect { issue(hours_worked: 55, bonus: 0) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /signed catch-up classification/)
      following_period = create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 28), pay_date: Date.new(2024, 2, 2))
      following = following_period.payroll_items.build(company: company, employee: employee, employment_type: "hourly", pay_rate: 15, hours_worked: 60)
      expect { PayrollCalculator.for(employee, following).calculate }.to raise_error(PayrollRetirementCatchUp::UnprovedHistoryError, /signed catch-up classification/)
      expect(period.supplemental_pay_periods.count).to eq(2)
    end
  end
  it "holds missing classification proof even when the annual retirement amounts are all zero" do
    original!
    correction = issue(hours_worked: 65)
    context = correction.calculation_context_snapshot.deep_dup
    context.fetch("corrective_paycheck").delete("catch_up_ledger_version")
    correction.update_columns(calculation_context_snapshot: context)
    expect { preview(hours_worked: 70) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /signed catch-up classification/)
    expect { issue(hours_worked: 70) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /signed catch-up classification/)
    expect(period.supplemental_pay_periods.count).to eq(1)
  end
end
