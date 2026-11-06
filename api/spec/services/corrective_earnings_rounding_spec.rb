# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Corrective paycheck earnings rounding" do
  include_context "corrective payroll ledger fixtures"

  let!(:rate) { create(:employee_wage_rate, employee: employee, label: "Captured wage", rate: "10.50", is_primary: true) }

  def rounded_original(legacy: false)
    columns = { "wage_rate_hours" => [ { "employee_wage_rate_id" => rate.id, "label" => rate.label,
      "rate" => 10.5, "regular_hours" => 0.01, "overtime_hours" => 0.01, "holiday_hours" => 0,
      "pto_hours" => 0, "active" => true } ] }
    original!(pay_rate: "10.50", hours_worked: "0.01", overtime_hours: "0.01", custom_columns_data: columns) do |item|
      if legacy
        context = item.calculation_context_snapshot.except("earnings_rounding")
        PayrollCalculator.for(employee, item, calculation_context: context).calculate
      end
    end
  end

  it "replays the captured saved-line rule through positive, repeated and negative supplementals" do
    original = rounded_original
    frozen = freeze_history(original)
    expect(original.gross_pay).to eq("0.27".to_d)
    first = issue(hours_worked: "0.02")
    expect(first.gross_pay).to eq("0.10".to_d)
    second = issue(hours_worked: "0.03", bonus: 1)
    expect(second.gross_pay).to eq("1.11".to_d)
    reversal = issue(hours_worked: "0.01", bonus: 0)
    expect(reversal.gross_pay).to eq("-1.21".to_d)
    [ first, second, reversal ].each { |item| assert_cash(item) }
    expect([ original, first, second, reversal ].sum(&:gross_pay)).to eq(original.gross_pay)
    expect(freeze_history(original.reload)).to eq(frozen)
  end

  it "retains legacy gross and discloses only the change in historical rounding on the supplemental" do
    original = rounded_original(legacy: true)
    frozen = freeze_history(original)
    expect(original.gross_pay).to eq("0.26".to_d)
    expect(original.payroll_item_earnings.sum(:amount)).to eq("0.27".to_d)
    first = issue(hours_worked: "0.02")
    expect(first.gross_pay).to eq("0.11".to_d)
    expect(first.payroll_item_earnings.find_by!(label: "Historical earnings rounding").amount).to eq("0.01".to_d)
    second = issue(hours_worked: "0.03", bonus: 1)
    reversal = issue(hours_worked: "0.01", bonus: 0)
    [ first, second, reversal ].each { |item| assert_cash(item) }
    expect([ original, first, second, reversal ].sum(&:gross_pay)).to eq("0.26".to_d)
    expect(freeze_history(original.reload)).to eq(frozen)
  end

  it "does not disguise missing historical wage detail as a rounding residual" do
    original = rounded_original(legacy: true)
    original.payroll_item_earnings.find_by!(category: "overtime").delete
    frozen = freeze_history(original.reload)
    expect { issue(hours_worked: "0.02") }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /historical.*earning|historical.*snapshot/i)
    expect(freeze_history(original.reload)).to eq(frozen)
    expect(period.supplemental_pay_periods).to be_empty
  end
end
