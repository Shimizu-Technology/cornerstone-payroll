# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"
require "roo"
require "tmpdir"

RSpec.describe "Corrective component ledger" do
  include_context "corrective payroll ledger fixtures"

  [
    [ "pre_tax", "retirement", "401k_pre_tax" ],
    [ "post_tax", "retirement", "401k_after_tax" ],
    [ "employer_contribution", "retirement", "401k_pre_tax" ],
    [ "pre_tax", "benefit", nil ], [ "post_tax", "garnishment", nil ],
    [ "post_tax", "child_support", nil ], [ "post_tax", "other", nil ],
    [ "post_tax", "insurance", nil ], [ "employer_contribution", "benefit", nil ]
  ].each do |category, sub_category, group|
    [ :first, :second ].each do |voided|
      it "reconciles signed #{category}/#{sub_category}/#{group} through repeated corrections and void #{voided}" do
        type = add_deduction(category: category, sub_category: sub_category, reporting_group: group)
        original = original!
        frozen = original.attributes
        first = issue(hours_worked: 65)
        expect(first.payroll_item_deductions.find_by!(deduction_type: type).amount).to eq(3.75)
        expect(first.insurance_payment).to eq(sub_category == "insurance" ? 3.75 : 0)
        second = issue(hours_worked: 55)
        expect(second.payroll_item_deductions.find_by!(deduction_type: type).amount).to eq(-7.5)
        [ original, first, second ].each { |item| assert_cash(item) }
        stale = preview(hours_worked: 60).dig(:meta, :review_digest)
        removed, retained = voided == :first ? [ first, second ] : [ second, first ]
        PayPeriodCorrectionService.void!(pay_period: removed.pay_period, actor: actor, reason: "Reverse selected supplemental")
        expect { issue({ hours_worked: 60 }, digest: stale) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
        repair = issue(hours_worked: 60)
        active = [ original, retained, repair ]
        expect(active.sum { |item| item.payroll_item_deductions.where(deduction_type: type).sum(:amount) }).to eq(45)
        expect { issue(hours_worked: 60) }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /already recorded/)
        expect(original.reload.attributes).to eq(frozen)
        assert_cash(repair)
        if group && category != "employer_contribution"
          key = group == "401k_after_tax" ? :roth_retirement : :retirement
          expect(employee.ytd_totals_for(2024).reload.public_send(key)).to eq(45)
          expect(PayrollRetirementTotals.for_scope(employee.payroll_items.financially_reportable.joins(:pay_period).merge(PayPeriod.reportable_committed))[key]).to eq(45)
        end
        if sub_category.in?(%w[retirement benefit garnishment child_support])
          liability_category = case sub_category
          when "retirement" then category == "employer_contribution" ? "retirement_employer" : "retirement_employee"
          when "benefit" then category == "employer_contribution" ? "benefit_employer" : "benefit_employee"
          else sub_category
          end
          expect(company.payroll_liability_entries.where(category: liability_category).sum(:amount)).to eq(45)
        end
      end
    end
  end

  [ [ "addition", "taxable_addition" ], [ "addition", "non_taxable_addition" ],
    [ "deduction", "pre_tax_deduction" ], [ "deduction", "post_tax_deduction" ],
    [ "employer_contribution", "employer_contribution" ] ].each do |kind, treatment|
    [ :first, :second ].each do |voided|
      it "retains #{treatment} field identity and its mirror through void #{voided}" do
        field = PayrollFieldDefinition.create!(company: company, name: "Synthetic #{treatment}", kind: kind,
          tax_treatment: treatment, category: "other", amount_type: "percentage", default_percentage: 5, active: true)
        employee.employee_payroll_fields.create!(payroll_field_definition: field, active: true)
        original = original!
        first = issue(hours_worked: 65)
        second = issue(hours_worked: 55)
        original_amount = original.payroll_item_field_entries.find_by!(payroll_field_definition: field).amount
        first_amount = first.payroll_item_field_entries.find_by!(payroll_field_definition: field).amount
        second_amount = second.payroll_item_field_entries.find_by!(payroll_field_definition: field).amount
        expect(first_amount).to be_positive
        expect(second_amount).to eq(-2 * first_amount)
        [ original, first, second ].each { |item| assert_cash(item) }
        removed, retained = voided == :first ? [ first, second ] : [ second, first ]
        stale = preview(hours_worked: 60).dig(:meta, :review_digest)
        PayPeriodCorrectionService.void!(pay_period: removed.pay_period, actor: actor, reason: "Reverse field delta")
        expect { issue({ hours_worked: 60 }, digest: stale) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
        repair = issue(hours_worked: 60)
        expect([ original, retained, repair ].sum { |item| item.payroll_item_field_entries.sum(:amount) }).to eq(original_amount)
        expect { issue(hours_worked: 60) }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError)
        assert_cash(repair)
      end
    end
  end

  it "records bonus +100/+50/-150, non-taxable cash, and custom earning/deduction reversals" do
    original = original!
    first = issue(bonus: 100, non_taxable_pay: 100, custom_earnings: [ { "label" => "Shift", "amount" => 25 } ],
      custom_deductions: [ { "label" => "Uniform", "amount" => 10 } ])
    second = issue(bonus: 150, non_taxable_pay: 150, custom_earnings: [ { "label" => "Shift", "amount" => 50 } ],
      custom_deductions: [ { "label" => "Uniform", "amount" => 15 } ])
    third = issue(bonus: 0, non_taxable_pay: 0, custom_earnings: [], custom_deductions: [])
    expect([ first, second, third ].map(&:bonus)).to eq([ 100, 50, -150 ])
    expect(third.non_taxable_pay).to eq(-150)
    expect(third.custom_earnings).to eq([ { "label" => "Shift", "amount" => -50.0 } ])
    expect(third.custom_deductions).to eq([ { "label" => "Uniform", "amount" => -15.0 } ])
    expect(employee.ytd_totals_for(2024).reload.bonus).to eq(0)
    [ original, first, second, third ].each { |item| assert_cash(item) }
  end

  it "retains a rate-only correction as earning money with zero hour delta" do
    original = original!(overtime_hours: 5)
    correction = issue(pay_rate: 16)
    expect(correction.hours_worked).to eq(0)
    expect(correction.overtime_hours).to eq(0)
    expect(correction.payroll_item_earnings.where(category: "regular").sum(:amount)).to eq(60)
    expect(correction.overtime_pay).to eq(7.5)
    assert_cash(correction)
    expect(original.reload.pay_rate).to eq(15)
  end

  it "holds a changed loan component atomically" do
    add_deduction(category: "post_tax", sub_category: "loan")
    original!
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /loan.*review|review.*loan/i)
    expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError)
    expect(period.supplemental_pay_periods).to be_empty
  end

  it "renders signed negative tax/contribution/other-pay detail with opposite cash effects" do
    add_deduction(category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
    original!(non_taxable_pay: 100)
    correction = issue(hours_worked: 55, non_taxable_pay: 50, additional_withholding_override: 5)
    assert_cash(correction)
    generator = PayrollSummaryByEmployeePdfGenerator.new(correction.pay_period)
    expect(generator.send(:money, -5, negative: true)).to eq("$5.00")
    expect(generator.send(:money, 5, negative: true)).to eq("-$5.00")
    expect(generator.send(:money, 0, negative: true)).to eq("$0.00")
    text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join(" ").gsub(/\s+/, " ")
    expect(text).to include("401(k)", "$3.75", "Non-Taxable Pay", "-$50.00")
    expect(QuickbooksPayrollReportData.new(correction.pay_period).retirement_rows.sole.employee_amount).to eq(-3.75)
  end
  [ "401k_pre_tax", "401k_after_tax" ].each do |group|
    it "ties signed retirement fields and their deduction mirrors to W-2 #{group}" do
      treatment = group == "401k_pre_tax" ? "pre_tax_deduction" : "post_tax_deduction"
      field = create(:payroll_field_definition, company: company, name: "Plan field #{group}", kind: "deduction",
        tax_treatment: treatment, category: "retirement", reporting_group: group, amount_type: "percentage", default_percentage: 5)
      employee.employee_payroll_fields.create!(payroll_field_definition: field)
      verify_synthetic_retirement_plan!(employee, period.pay_date)
      original = original!
      first = issue(hours_worked: 65)
      expect(first.payroll_item_field_entries.sole.amount).to eq(3.75)
      expect(first.payroll_item_deductions.sole.amount).to eq(3.75)
      totals = W2GuAggregator.new(company, 2024).generate.fetch(:totals)
      key = group == "401k_pre_tax" ? :box12_code_d_total : :box12_code_aa_total
      expect(totals[key]).to eq(48.75)
      second = issue(hours_worked: 55)
      expect(W2GuAggregator.new(company, 2024).generate.fetch(:totals)[key]).to eq(41.25)
      PayPeriodCorrectionService.void!(pay_period: first.pay_period, actor: actor, reason: "Reverse first plan delta")
      expect(W2GuAggregator.new(company, 2024).generate.fetch(:totals)[key]).to eq(37.5)
      repair = issue(hours_worked: 65)
      expect(W2GuAggregator.new(company, 2024).generate.fetch(:totals)[key]).to eq(48.75)
      [ original, second, repair ].each { |item| assert_cash(item) }
      expect(company.payroll_liability_entries.where(category: "retirement_employee").sum(:amount)).to eq(48.75)
    end
  end

  it "keeps built-in traditional/Roth employee and employer deltas exactly once" do
    employee.update!(retirement_rate: 0.03, roth_retirement_rate: 0.02, employer_retirement_match_rate: 0.01)
    verify_synthetic_retirement_plan!(employee, period.pay_date)
    original!
    first = issue(hours_worked: 65)
    second = issue(hours_worked: 55)
    expect(first.retirement_payment).to eq(2.25)
    expect(second.retirement_payment).to eq(-4.5)
    expect(second.roth_retirement_payment).to eq(-3)
    expect(second.employer_retirement_match).to eq(-1.5)
    expect(second.payroll_item_deductions).to be_empty
    data = QuickbooksPayrollReportData.new(second.pay_period)
    expect(data.retirement_rows.sum(&:employee_amount)).to eq(-7.5)
    expect(data.retirement_rows.sum(&:company_amount)).to eq(-1.5)
    assert_cash(second)
    PayPeriodCorrectionService.void!(pay_period: second.pay_period, actor: actor, reason: "Reverse built-in deltas")
    expect(employee.ytd_totals_for(2024).reload.retirement).to eq(29.25)
    expect(company.payroll_liability_entries.where(category: "retirement_employer").sum(:amount)).to eq(9.75)
  end

  [ :first, :second ].each do |voided|
    it "repairs cash/bonus/tips/custom components after void #{voided}" do
      original = original!(bonus: 10, non_taxable_pay: 20, reported_tips: 10, tips_paid_out: 5,
        payroll_adjustments: [ { "label" => "Fixed reimbursement", "amount" => 12, "treatment" => "non_taxable_addition" },
          { "label" => "Fixed deduction", "amount" => 7, "treatment" => "pre_tax_deduction" } ])
      target = { bonus: 100, non_taxable_pay: 100, reported_tips: 30, tips_paid_out: 15, service_charge_wages: 25,
        qualified_overtime_compensation: 5, custom_earnings: [ { "label" => "Premium", "amount" => 25 } ],
        custom_deductions: [ { "label" => "Uniform", "amount" => 5 } ] }
      first = issue(target)
      second = issue(target.merge(bonus: 50, non_taxable_pay: 50, reported_tips: 20, tips_paid_out: 10, service_charge_wages: 10,
        qualified_overtime_compensation: 2, custom_earnings: [], custom_deductions: []))
      removed, retained = voided == :first ? [ first, second ] : [ second, first ]
      stale = preview(target).dig(:meta, :review_digest)
      PayPeriodCorrectionService.void!(pay_period: removed.pay_period, actor: actor, reason: "Reverse cash component delta")
      expect { issue(target, digest: stale) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
      target = target.merge(bonus: 125)
      repair = issue(target)
      [ original, retained, repair ].each { |item| assert_cash(item) }
      target.slice(:bonus, :non_taxable_pay, :reported_tips, :tips_paid_out, :service_charge_wages, :qualified_overtime_compensation).each do |field, expected|
        expect([ original, retained, repair ].sum { |item| item.public_send(field).to_d }).to eq(expected)
      end
      expect(first.payroll_adjustments).to be_empty
      expect(repair.payroll_adjustments).to be_empty
      expect { issue(target) }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError)
    end
  end

  it "records a zero-net custom component reclassification instead of dropping it" do
    original!(custom_earnings: [ { "label" => "Old premium", "amount" => 25 } ])
    correction = issue(custom_earnings: [ { "label" => "New premium", "amount" => 25 } ])
    expect(correction.net_pay).to eq(0)
    expect(correction.custom_earnings).to contain_exactly({ "label" => "New premium", "amount" => 25.0 }, { "label" => "Old premium", "amount" => -25.0 })
    assert_cash(correction)
  end

  it "keeps ordinary fields, earnings and JSON inputs nonnegative" do
    item = original!
    field = build(:payroll_item_field_entry, payroll_item: item, amount: -1)
    expect(field).not_to be_valid
    earning = item.payroll_item_earnings.build(category: "other", label: "Invalid negative hours", amount: -1, hours: -1)
    expect(earning).not_to be_valid
    expect(PayrollItem.normalize_custom_deduction_entries([ { "label" => "Invalid", "amount" => -1 } ])).to be_empty
    expect(PayrollItem.normalize_payroll_adjustments([ { "label" => "Invalid", "amount" => -1, "treatment" => "post_tax_deduction" } ])).to be_empty
  end

  it "holds ambiguous historical earning detail and unsupported custom columns" do
    original = original!
    original.payroll_item_earnings.delete_all
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /reconcile/)
    expect { issue(custom_columns_data: { "unreviewed_cash" => 100 }) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /component-level review/)
    expect(period.supplemental_pay_periods).to be_empty
  end

  it "preserves signed regular, overtime, holiday and PTO earnings across a void" do
    original = original!(overtime_hours: 5, holiday_hours: 3, pto_hours: 2)
    first = issue(hours_worked: 65, overtime_hours: 7, holiday_hours: 4, pto_hours: 1)
    second = issue(hours_worked: 55, overtime_hours: 1, holiday_hours: 1, pto_hours: 0)
    PayPeriodCorrectionService.void!(pay_period: first.pay_period, actor: actor, reason: "Reverse all hour changes")
    target = { hours_worked: 70, overtime_hours: 8, holiday_hours: 5, pto_hours: 4 }
    repair = issue(target)
    [ original, second, repair ].each { |item| assert_cash(item) }
    target.each do |field, amount|
      expect([ original, second, repair ].sum { |item| item.public_send(field).to_d }).to eq(amount)
    end
    expect(employee.ytd_totals_for(2024).reload.overtime_pay).to eq(180)
  end

  it "retains salary nonexempt overtime as signed earning deltas from the saved coverage" do
    employee.update!(employment_type: "salary", salary_type: "annual", pay_rate: 52000)
    original = original!(employment_type: "salary", pay_rate: 52000, hours_worked: 0, overtime_hours: 5,
      timekeeping_context_snapshot: { "overtime_status" => "nonexempt", "salary_covers_weekly_hours" => 40,
        "salary_type" => "annual", "pay_frequency" => "biweekly", "salary_uncovered_overtime_hours" => 5 })
    first = issue(pay_rate: 54600)
    second = issue(pay_rate: 46800)
    expect(first.overtime_pay).to eq(9.38)
    expect(second.overtime_pay).to eq(-28.13)
    PayPeriodCorrectionService.void!(pay_period: first.pay_period, actor: actor, reason: "Reverse salary overtime delta")
    repair = issue(pay_rate: 54600)
    expect { issue(overtime_hours: 8) }.to raise_error(IssueCorrectivePaycheckService::UnsupportedEmployeeError, /daily salary-coverage/)
    [ original, second, repair ].each { |item| assert_cash(item) }
    expect(employee.ytd_totals_for(2024).reload.overtime_pay).to eq(196.88)
  end

  it "does not repay or change an unchanged scheduled loan while correcting wages" do
    type = DeductionType.create!(company: company, name: "Fixed tracked loan", category: "post_tax", sub_category: "loan")
    employee.employee_deductions.create!(deduction_type: type, amount: 50, active: true)
    loan = EmployeeLoan.create!(employee: employee, company: company, deduction_type: type, name: "Fixed tracked loan",
      original_amount: 1000, current_balance: 1000, opening_balance: 1000, balance_as_of: Date.new(2024, 1, 1),
      balance_source: "other_verified", payment_amount: 50, first_deduction_date: Date.new(2024, 1, 1),
      start_date: Date.new(2024, 1, 1), status: "active")
    original = original!
    loan.loan_transactions.create!(payroll_item: original, transaction_type: "payment", amount: 50,
      balance_before: 1000, balance_after: 950, transaction_date: period.pay_date)
    loan.update!(current_balance: 950)
    before = loan.reload.attributes
    transactions = loan.loan_transactions.map(&:attributes)
    correction = issue(hours_worked: 65)
    expect(correction.loan_payment).to eq(0)
    expect(correction.payroll_item_deductions).to be_empty
    expect(loan.reload.attributes).to eq(before)
    expect(loan.loan_transactions.reload.map(&:attributes)).to eq(transactions)
    assert_cash(correction)
  end

  it "holds historical employer insurance folded into an employee aggregate" do
    add_deduction(category: "employer_contribution", sub_category: "insurance")
    original = original!
    original.update_columns(insurance_payment: 45)
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /employer insurance.*review/i)
    expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError)
    expect(period.supplemental_pay_periods).to be_empty
  end

  [ :first, :second ].each do |voided|
    it "reconciles net-only non-taxable corrections through void #{voided}" do
      original = original!
      first = issue(non_taxable_pay: 100)
      second = issue(non_taxable_pay: 50)
      expect(first.gross_pay).to eq(0)
      expect(first.net_pay).to eq(100)
      expect(second.net_pay).to eq(-50)
      removed, retained = voided == :first ? [ first, second ] : [ second, first ]
      stale = preview(non_taxable_pay: 75).dig(:meta, :review_digest)
      PayPeriodCorrectionService.void!(pay_period: removed.pay_period, actor: actor, reason: "Reverse non-taxable cash adjustment")
      expect { issue({ non_taxable_pay: 75 }, digest: stale) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
      repair = issue(non_taxable_pay: 75)
      expect([ original, retained, repair ].sum(&:non_taxable_pay)).to eq(75)
      [ first, second, repair ].each { |item| assert_cash(item) }
      expect { issue(non_taxable_pay: 75) }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError)
    end
  end

  describe "signed register exports", type: :request do
    it "keeps negative custom deductions in the JSON register and signed hours in the employee workbook" do
      original!(custom_deductions: [ { "label" => "Uniform", "amount" => 10 } ])
      correction = issue(hours_worked: 55, custom_deductions: [ { "label" => "Uniform", "amount" => 5 } ])
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(actor)
      get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: correction.pay_period_id }
      expect(response).to have_http_status(:ok)
      worker = response.parsed_body.fetch("report").fetch("employees").sole
      expect(worker.fetch("deductions_breakdown")).to include(hash_including("label" => "Uniform", "amount" => -5))
      get "/api/v1/admin/reports/payroll_summary_by_employee_xlsx", params: { pay_period_id: correction.pay_period_id }
      expect(response).to have_http_status(:ok)
      Tempfile.create([ "signed-correction", ".xlsx" ]) do |file|
        file.binmode
        file.write(response.body)
        file.flush
        workbook = Roo::Excelx.new(file.path)
        rows = workbook.sheet("QB Summary Matrix").to_a
        expect(rows).to include([ "Hours - Regular Pay", -5, -5 ])
      end
    end
  end

  describe "negative full package", type: :request do
    it "renders the real endpoint with signed summary, deductions, retirement and paycheck history" do
      add_deduction(category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
      add_deduction(category: "employer_contribution", sub_category: "benefit")
      original!(non_taxable_pay: 100, additional_withholding_override: 10)
      correction = issue(hours_worked: 55, non_taxable_pay: 50, additional_withholding_override: 5)
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(actor)
      post "/api/v1/admin/reports/full_print_package_pdf", params: { pay_period_id: correction.pay_period_id }
      expect(response).to have_http_status(:ok)
      reader = PDF::Reader.new(StringIO.new(response.body))
      text = reader.pages.map(&:text).join(" ").gsub(/\s+/, " ")
      expect(text.downcase).to include("payroll summary by employee", "retirement plans report", "deductions and contributions", "paycheck history")
      summary = reader.pages.find { |page| page.text.include?("Payroll summary by employee") }.text.gsub(/\s+/, " ")
      expect(summary).to include("Withholding", "$5.00", "$3.75", "-$50.00")
      row = PayrollSummaryByEmployeePdfGenerator.new(correction.pay_period).send(:employee_row, correction)
      expect(row[4]).to include("Additional Withholding    $5.00")
      expect(row[2]).to include("$3.75")
      expect(row[3]).to include("Non-Taxable Pay    -$50.00")
      expect(summary).not_to include("Additional Withholding -$5.00")
      expect(text).to include("$-3.75", "Other pay", "Gross pay plus other pay minus total deductions equals net pay.")
      assert_cash(correction)
      data = QuickbooksPayrollReportData.new(correction.pay_period)
      expect(data.paycheck_history_rows.sole[:deductions]).to eq(correction.total_deductions.to_f)
      expect(data.retirement_rows.sole.employee_amount).to eq(-3.75)
      if ENV["PAYROLL_LEDGER_PDF_ARTIFACTS_DIR"].present?
        directory = Dir.mktmpdir("corrective-ledger-", ENV.fetch("PAYROLL_LEDGER_PDF_ARTIFACTS_DIR"))
        File.binwrite(File.join(directory, "negative-package.pdf"), response.body)
        File.binwrite(File.join(directory, "negative-summary.pdf"), PayrollSummaryByEmployeePdfGenerator.new(correction.pay_period).generate)
      end
    end
  end
end
