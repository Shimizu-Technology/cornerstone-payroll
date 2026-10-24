# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PR381 ordinary insurance obligation probe" do
  include_context "corrective payroll ledger fixtures"

  it "retains the employer insurance obligation when ordinary available-pay capping runs" do
    add_deduction(category: "employer_contribution", sub_category: "insurance", percentage: 3)
    item=original!(bonus: 20, non_taxable_pay: 100, custom_deductions: [ { "label"=>"Big deduction", "amount"=>1000 } ])
    expected=item.payroll_item_deductions.select(&:employer_contribution?).sum(&:amount)
    entries=company.payroll_liability_entries.where(payroll_item_id: item.id).where(category: "benefit_employer")
    expect(PayrollStatementYtdBreakdown.new(item).employer_contributions.sum(&:current)).to eq(expected)
    expect(expected).to eq(27.6)
    expect(entries.sum(:amount)).to eq(expected)
    expect(item.insurance_payment).to eq(0)
    expect(company.payroll_liability_entries.where(payroll_item_id: item.id, category: "insurance_employee")).to be_empty
  end

  [ false, true ].product([ false, true ]).each do |first_capped, second_capped|
    it "posts employer insurance once through capped #{first_capped} to #{second_capped} ordinary payroll" do
      add_deduction(category: "employer_contribution", sub_category: "insurance", percentage: 3)
      original = original!(bonus: 20, non_taxable_pay: 100, custom_deductions: first_capped ? [ { "label" => "Big deduction", "amount" => 1000 } ] : [])
      following_period = create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 28), pay_date: Date.new(2024, 2, 2))
      following = following_period.payroll_items.build(company: company, employee: employee, employment_type: "hourly", pay_rate: 15, hours_worked: 65,
        bonus: 20, non_taxable_pay: 100, custom_deductions: second_capped ? [ { "label" => "Big deduction", "amount" => 1000 } ] : [])
      PayrollCalculator.for(employee, following).calculate
      following.save!
      PayrollLiabilityPostingService.post!(pay_period: following_period, actor: actor)
      expect(company.payroll_liability_entries.where(category: "benefit_employer").sum(:amount)).to eq(57.45)
      expect(company.payroll_liability_entries.where(category: "insurance_employee")).to be_empty
      [ original, following ].each do |item|
        expect(item.insurance_payment).to eq(0)
        expect { PayrollLiabilityPostingService.verify_employer_contributions!(item) }.not_to raise_error
        assert_cash(item)
      end
    end
  end

  [ false, true ].each do |capped|
    it "posts signed employer-insurance fields in ordinary and corrective payroll capped=#{capped}" do
      field = create(:payroll_field_definition, company: company, name: "Employer health", kind: "employer_contribution", tax_treatment: "employer_contribution", category: "insurance", amount_type: "percentage", default_percentage: 3)
      employee.employee_payroll_fields.create!(payroll_field_definition: field)
      original = original!(bonus: 20, custom_deductions: capped ? [ { "label" => "Big deduction", "amount" => 1000 } ] : [])
      correction = issue(hours_worked: 65)
      refund = issue(hours_worked: 55)
      expect([ original, correction, refund ].map { |item| item.pay_period.payroll_liability_postings.sole.entries.where(category: "benefit_employer").sum(:amount) }).to eq([ 27.6, 2.25, -4.5 ])
      [ original, correction, refund ].each { |item| PayrollLiabilityPostingService.verify_employer_contributions!(item) }
      expect(company.payroll_liability_entries.where(category: "benefit_employer").sum(:amount)).to eq(25.35)
    end
  end

  [ false, true ].product([ :first, :second ]).each do |capped, voided|
    it "reconciles direct employer insurance capped=#{capped} through repeat, void #{voided} and repair" do
      type = add_deduction(category: "employer_contribution", sub_category: "insurance", percentage: 3)
      original = original!(bonus: 20, custom_deductions: capped ? [ { "label" => "Big deduction", "amount" => 1000 } ] : [])
      frozen = freeze_history(original)
      first = issue(hours_worked: 65)
      second = issue(hours_worked: 55)
      expect([ original, first, second ].map { |item| item.payroll_item_deductions.find_by!(deduction_type: type).amount }).to eq([ 27.6, 2.25, -4.5 ])
      stale = preview(hours_worked: 60).dig(:meta, :review_digest)
      removed, retained = voided == :first ? [ first, second ] : [ second, first ]
      PayPeriodCorrectionService.void!(pay_period: removed.pay_period, actor: actor, reason: "Reverse employer insurance delta")
      expect { issue({ hours_worked: 60 }, digest: stale) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
      repair = issue(hours_worked: 60)
      expect([ original, retained, repair ].sum { |item| item.payroll_item_deductions.find_by!(deduction_type: type).amount }).to eq(27.6)
      expect(company.payroll_liability_entries.where(category: "benefit_employer").sum(:amount)).to eq(27.6)
      expect(company.payroll_liability_entries.where(category: "insurance_employee")).to be_empty
      [ original, retained, repair ].each do |item|
        expect(item.insurance_payment).to eq(0)
        PayrollLiabilityPostingService.verify_employer_contributions!(item)
        assert_cash(item)
      end
      expect { issue(hours_worked: 60) }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /already recorded/)
      expect(freeze_history(original.reload)).to eq(frozen)
    end
  end

  it "rolls back a new ordinary posting if an employer component is omitted" do
    add_deduction(category: "employer_contribution", sub_category: "benefit", percentage: 3)
    allow_any_instance_of(PayrollLiabilityPostingService).to receive(:itemized_liability_rows).and_return([])
    expect { original! }.to raise_error(PayrollLiabilityPostingService::InvalidStateError, /employer contribution.*reconcile/i)
    expect(period.payroll_liability_postings).to be_empty
  end

  it "rolls back a corrective issue if an employer component is omitted from its posting" do
    add_deduction(category: "employer_contribution", sub_category: "benefit", percentage: 3)
    original!
    before = employee.ytd_totals_for(2024).reload.attributes
    allow_any_instance_of(PayrollLiabilityPostingService).to receive(:itemized_liability_rows).and_return([])
    expect { issue(hours_worked: 65) }.to raise_error(PayrollLiabilityPostingService::InvalidStateError, /employer contribution.*reconcile/i)
    expect(period.supplemental_pay_periods).to be_empty
    expect(employee.ytd_totals_for(2024).reload.attributes).to eq(before)
  end
end
