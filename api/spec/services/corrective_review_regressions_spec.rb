# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Corrective paycheck review regressions" do
  include_context "corrective payroll ledger fixtures"

  def later!(**inputs)
    later_period = create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 28), pay_date: Date.new(2024, 2, 2))
    item = later_period.payroll_items.build(company: company, employee: employee, employment_type: "hourly", pay_rate: 15, hours_worked: 60, **inputs)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    employee.ytd_totals_for(2024).add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(item)
    PayrollLiabilityPostingService.post!(pay_period: later_period, actor: actor)
    item
  end

  def statement_assertions(item, active)
    breakdown = PayrollStatementYtdBreakdown.new(item)
    stub = PayStubGenerator.new(item)
    check = CheckGenerator.new(item)
    expected = active.sum { |row| PayrollRetirementTotals.for_item(row)[:retirement] }
    expect(breakdown.deductions.sum(&:ytd)).to eq(expected)
    expect(breakdown.employer_contributions.sum(&:ytd)).to eq(expected)
    expect(breakdown.other_pay.sum(&:ytd)).to eq(active.sum(&:non_taxable_pay))
    expect(stub.send(:current_total_deductions)).to eq(item.total_deductions)
    expect(check.send(:cur_deds)).to eq(breakdown.deductions.sum(&:current))
    expect(check.send(:ytd)[:net]).to eq(active.sum(&:net_pay).to_f)
    expect(item.ytd_net).to eq(active.sum(&:net_pay))
    expect(item.ytd_withholding_tax).to eq(active.sum(&:withholding_tax))
    expect(item.ytd_social_security_tax).to eq(active.sum(&:social_security_tax))
    expect(item.ytd_medicare_tax).to eq(active.sum(&:medicare_tax))
    check_pdf = if item.net_pay.negative?
      document = Prawn::Document.new(page_size: "LETTER", margin: 0)
      check.send(:draw_stub, document, check.send(:stub1_y), false)
      document.render
    else
      check.generate
    end
    [ stub.generate, check_pdf ].each do |bytes|
      text = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ")
      expect(text).to include("401(k)")
    end
  end

  it "retains signed statement components on the negative corrective stub" do
    add_deduction(category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
    add_deduction(category: "employer_contribution", sub_category: "benefit")
    original!(non_taxable_pay: 100)
    issue(hours_worked: 65, non_taxable_pay: 150)
    second = issue(hours_worked: 55, non_taxable_pay: 50)
    breakdown = PayrollStatementYtdBreakdown.new(second)
    generator = PayStubGenerator.new(second)
    aggregate_failures do
      expect(breakdown.deductions.sum(&:current)).to eq(-7.5)
      expect(breakdown.other_pay.sum(&:current)).to eq(-100)
      expect(breakdown.employer_contributions.sum(&:current)).to eq(-7.5)
      expect(generator.send(:current_total_deductions)).to eq(second.total_deductions)
    end
  end
  it "carries reversals into the next ordinary paystub and check YTD" do
    add_deduction(category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
    add_deduction(category: "employer_contribution", sub_category: "benefit")
    original!(non_taxable_pay: 100)
    issue(hours_worked: 65, non_taxable_pay: 150)
    issue(hours_worked: 55, non_taxable_pay: 50)
    following_period = create(:pay_period, company: company, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 28), pay_date: Date.new(2024, 2, 2))
    following = following_period.payroll_items.build(company: company, employee: employee, employment_type: "hourly", pay_rate: 15, hours_worked: 60)
    PayrollCalculator.for(employee, following).calculate
    following.save!
    breakdown = PayrollStatementYtdBreakdown.new(following)
    aggregate_failures do
      expect(following.ytd_retirement).to eq(86.25)
      expect(breakdown.deductions.sum(&:ytd)).to eq(86.25)
      expect(breakdown.other_pay.sum(&:ytd)).to eq(50)
      expect(breakdown.employer_contributions.sum(&:ytd)).to eq(86.25)
    end
  end
  it "does not post an insurance field delta through both its scalar and field" do
    field = create(:payroll_field_definition, company: company, name: "Health field", kind: "deduction", tax_treatment: "post_tax_deduction", category: "insurance", amount_type: "percentage", default_percentage: 5)
    employee.employee_payroll_fields.create!(payroll_field_definition: field)
    original!
    corrected = issue(hours_worked: 65, custom_deductions: [ { "label"=>"Large uniform", "amount"=>1000 } ])
    entries = corrected.pay_period.payroll_liability_postings.sole.entries.where(category: "insurance_employee")
    expect(entries.sum(:amount)).to eq(3.75)
  end
  it "holds or caps a retirement increase when later payroll consumed the annual room" do
    add_deduction(category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
    original!
    later_period = create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 28), pay_date: Date.new(2024, 2, 2))
    later = later_period.payroll_items.build(company: company, employee: employee, employment_type: "hourly", pay_rate: 15, hours_worked: 0, bonus: 500000)
    PayrollCalculator.for(employee, later).calculate
    later.save!
    employee.ytd_totals_for(2024).add_payroll_item!(later)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(later)
    frozen = freeze_history(later)
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /annual retirement reconciliation/)
    expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /annual retirement reconciliation/)
    expect(employee.ytd_totals_for(2024).reload.retirement).to eq(23000)
    expect(freeze_history(later.reload)).to eq(frozen)
    expect(period.supplemental_pay_periods).to be_empty
  end

  [ :first, :second ].each do |voided|
    it "reconciles negative and following statements after void #{voided}" do
      add_deduction(category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
      add_deduction(category: "employer_contribution", sub_category: "benefit")
      original = original!(non_taxable_pay: 100)
      frozen = freeze_history(original)
      first = issue(hours_worked: 65, non_taxable_pay: 150)
      second = issue(hours_worked: 55, non_taxable_pay: 50)
      statement_assertions(second, [ original, first, second ])
      following = later!
      statement_assertions(following, [ original, first, second, following ])
      removed, retained = voided == :first ? [ first, second ] : [ second, first ]
      PayPeriodCorrectionService.void!(pay_period: removed.pay_period, actor: actor, reason: "Reverse signed statement")
      statement_assertions(following.reload, [ original, retained, following ])
      expect(freeze_history(original.reload)).to eq(frozen)
    end
  end

  [ false, true ].each do |starts_capped|
    [ :first, :second ].each do |voided|
      it "posts insurance exactly once across capped=#{starts_capped}, repeated corrections and void #{voided}" do
        field = create(:payroll_field_definition, company: company, name: "Health field", kind: "deduction", tax_treatment: "post_tax_deduction", category: "insurance", amount_type: "percentage", default_percentage: 5)
        employee.employee_payroll_fields.create!(payroll_field_definition: field)
        original = original!(custom_deductions: starts_capped ? [ { "label" => "Uniform", "amount" => 1000 } ] : [])
        frozen = freeze_history(original)
        first = issue(hours_worked: 65, custom_deductions: starts_capped ? [] : [ { "label" => "Uniform", "amount" => 1000 } ])
        second = issue(hours_worked: 55, custom_deductions: [])
        expect([ original, first, second ].map(&:insurance_payment)).to eq([ 0, 0, 0 ])
        expect(company.payroll_liability_entries.where(category: "insurance_employee").sum(:amount)).to eq(41.25)
        [ original, first, second ].each { |item| assert_cash(item) }
        stale = preview(hours_worked: 65).dig(:meta, :review_digest)
        removed, retained = voided == :first ? [ first, second ] : [ second, first ]
        PayPeriodCorrectionService.void!(pay_period: removed.pay_period, actor: actor, reason: "Reverse insurance delta")
        expect { issue({ hours_worked: 65 }, digest: stale) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
        repair = issue(hours_worked: 70, custom_deductions: [])
        expect(company.payroll_liability_entries.where(category: "insurance_employee").sum(:amount)).to eq(52.5)
        expect([ original, retained, repair ].sum { |item| PayrollInsuranceComponents.total(item) }).to eq(52.5)
        expect(freeze_history(original.reload)).to eq(frozen)
        assert_cash(repair)
      end
    end
  end

  it "holds insurance whose saved liability classification cannot be reconciled" do
    add_deduction(category: "post_tax", sub_category: "insurance")
    original = original!
    original.update_columns(insurance_payment: 12)
    frozen = freeze_history(original.reload)
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /Insurance.*provenance/)
    expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    expect(freeze_history(original.reload)).to eq(frozen)
    expect(period.supplemental_pay_periods).to be_empty
  end

  it "shares current annual room between traditional and Roth and releases it after a later void" do
    employee.update!(retirement_rate: 0.025, roth_retirement_rate: 0.025)
    verify_synthetic_retirement_plan!(employee, period.pay_date)
    original!
    later = later!(hours_worked: 0, bonus: 500000)
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    PayPeriodCorrectionService.void!(pay_period: later.pay_period, actor: actor, reason: "Release annual room")
    correction = issue(hours_worked: 65)
    expect(PayrollRetirementTotals.for_item(correction).values.sum).to eq(3.76)
  end

  [ :first, :second ].each do |voided|
    it "revalidates shared annual room after supplemental void #{voided}" do
      add_deduction(category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax", percentage: 50)
      original!
      first = issue(hours_worked: 65)
      second = issue(hours_worked: 55)
      later!(hours_worked: 0, bonus: 50000)
      removed = voided == :first ? first : second
      PayPeriodCorrectionService.void!(pay_period: removed.pay_period, actor: actor, reason: "Annual context changed")
      expect(employee.ytd_totals_for(2024).reload.retirement).to eq(voided == :first ? 22962.5 : 23075)
      repair = issue(hours_worked: 55)
      expect(PayrollRetirementTotals.for_item(repair)[:retirement]).to eq(voided == :first ? 37.5 : -75)
      expect(employee.ytd_totals_for(2024).reload.retirement).to eq(23000)
      expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    end
  end

  it "holds an earlier employer match increase after later payroll reached the plan cap" do
    employee.update!(employer_retirement_match_rate: 0.05)
    verify_synthetic_retirement_plan!(employee, period.pay_date, employer_match_annual_cap: 90)
    original!
    later!
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    correction = issue(hours_worked: 55)
    expect(correction.employer_retirement_match).to eq(-3.75)
  end

  it "makes an evidence-only annual contribution change stale even without FICA changes" do
    add_deduction(category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
    original!
    digest = preview(hours_worked: 65).dig(:meta, :review_digest)
    employee.employee_retirement_year_inputs.create!(company: company, tax_year: 2024, source_reference: "Verified outside plan", reason: "Annual context", external_roth_deferrals: 10)
    expect { issue({ hours_worked: 65 }, digest: digest) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
    expect(period.supplemental_pay_periods).to be_empty
  end

  it "holds employer contributions that exceed current annual additions after later payroll" do
    AnnualRetirementLimit.find_by!(tax_year: 2024).update!(annual_additions_limit: 100)
    employee.update!(employer_retirement_match_rate: 0.05)
    verify_synthetic_retirement_plan!(employee, period.pay_date)
    original!
    later!
    expect { preview(hours_worked: 80) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /annual retirement/)
    expect { issue(hours_worked: 80) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    expect(company.payroll_liability_entries.where(category: "retirement_employer").sum(:amount)).to eq(90)
  end

  it "rebuilds annual contribution evidence under the issue financial lock" do
    add_deduction(category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
    original!
    service = IssueCorrectivePaycheckService.new(original_pay_period: period, employee: employee,
      corrected_inputs: { hours_worked: 65 }, pay_date: Date.new(2024, 1, 26), reason: "Concurrent annual evidence", actor: actor)
    service.preview
    calls = 0
    allow(service).to receive(:validate_for_issue!).and_wrap_original do |method, *args|
      method.call(*args)
      calls += 1
      if calls == 1
        employee.employee_retirement_year_inputs.create!(company: company, tax_year: 2024,
          source_reference: "Verified external annual cap", reason: "Concurrent context", external_roth_deferrals: 23000)
      end
    end
    expect { service.issue! }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /annual retirement/)
    expect(period.supplemental_pay_periods).to be_empty
    expect(employee.ytd_totals_for(2024).reload.retirement).to eq(45)
  end

  it "holds an insurance history with duplicate posted liabilities without repairing it" do
    field = create(:payroll_field_definition, company: company, name: "Health field", kind: "deduction",
      tax_treatment: "post_tax_deduction", category: "insurance", amount_type: "percentage", default_percentage: 5)
    employee.employee_payroll_fields.create!(payroll_field_definition: field)
    original = original!
    entry = company.payroll_liability_entries.find_by!(payroll_item_id: original.id, category: "insurance_employee")
    PayrollLiabilityEntry.create!(entry.attributes.except("id", "created_at", "updated_at").merge("component_key" => "insurance_employee"))
    frozen = entry.reload.attributes
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /Saved insurance liability/)
    expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    expect(entry.reload.attributes).to eq(frozen)
    expect(period.supplemental_pay_periods).to be_empty
  end

  it "includes opening match verified by a later effective election in annual caps" do
    employee.update!(employer_retirement_match_rate: 0.05)
    verify_synthetic_retirement_plan!(employee, period.pay_date)
    original!
    verify_synthetic_retirement_plan!(employee, Date.new(2024, 1, 20), employer_match_annual_cap: 2000,
      employer_match_ytd_before_system: 1000)
    later = later!(hours_worked: 0, bonus: 19100)
    expect(later.employer_retirement_match).to eq(955)
    expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /annual retirement/)
    expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    expect(company.payroll_liability_entries.where(category: "retirement_employer").sum(:amount)).to eq(1000)
  end

  [ nil, 2 ].each do |version|
    it "holds active corrections with unsupported component ledger version #{version.inspect}" do
      add_deduction(category: "employer_contribution", sub_category: "benefit")
      original = original!
      legacy = issue(hours_worked: 65)
      context = legacy.calculation_context_snapshot.deep_dup
      context["corrective_paycheck"].delete("component_ledger_version")
      context["corrective_paycheck"]["component_ledger_version"] = version if version
      legacy.update_columns(calculation_context_snapshot: context)
      legacy.payroll_item_deductions.delete_all
      legacy.payroll_item_earnings.delete_all
      frozen = [ freeze_history(original), freeze_history(legacy.reload) ]
      postings = company.payroll_liability_entries.order(:id).map(&:attributes)
      expect { preview(hours_worked: 70) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /predates.*component ledger|component ledger.*review/i)
      expect { issue(hours_worked: 70) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /component ledger/i)
      expect(period.supplemental_pay_periods.count).to eq(1)
      expect([ freeze_history(original.reload), freeze_history(legacy.reload) ]).to eq(frozen)
      expect(company.payroll_liability_entries.order(:id).map(&:attributes)).to eq(postings)
    end
  end

  [ 65, 55 ].each do |hours|
    it "holds mismatched signed employer contribution detail for target #{hours}" do
      add_deduction(category: "employer_contribution", sub_category: "benefit")
      original!
      allow_any_instance_of(CorrectivePayrollComponents).to receive(:deduction_rows).and_wrap_original do |method|
        method.call.map do |row|
          row["category"] == "employer_contribution" ? row.merge("amount" => row.fetch("amount") * 2) : row
        end
      end
      expect { preview(hours_worked: hours) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /employer contribution.*reconcile/i)
      expect(PayrollLiabilityPostingService).not_to receive(:post!)
      expect { issue(hours_worked: hours) }.to raise_error(IssueCorrectivePaycheckService::CorrectionError, /employer contribution.*reconcile/i)
      expect(period.supplemental_pay_periods).to be_empty
    end
  end

  it "uses the governing 2024 election instead of superseded 2022 annual caps" do
    employee.update!(retirement_rate: 0.5, employer_retirement_match_rate: 0.05)
    verify_synthetic_retirement_plan!(employee, Date.new(2022, 1, 1), plan_annual_employee_limit: 10000, employer_match_annual_cap: 50)
    verify_synthetic_retirement_plan!(employee, Date.new(2024, 1, 1), plan_annual_employee_limit: 23000, employer_match_annual_cap: 2000)
    original!
    later!(hours_worked: 0, bonus: 21000)
    expect(preview(hours_worked: 70).dig(:deltas, :retirement_payment)).to eq(75)
    correction = issue(hours_worked: 70)
    expect(correction.retirement_payment).to eq(75)
    expect(correction.employer_retirement_match).to eq(7.5)
    expect(employee.ytd_totals_for(2024).reload.retirement).to eq(11025)
  end

  it "uses an amended current-year cap while retaining historical target and opening evidence" do
    employee.update!(retirement_rate: 0.5)
    verify_synthetic_retirement_plan!(employee, Date.new(2022, 1, 1), regular_plan_deferral_limit: 500, plan_annual_employee_limit: 500)
    original!
    verify_synthetic_retirement_plan!(employee, Date.new(2024, 1, 20), regular_plan_deferral_limit: 1000, plan_annual_employee_limit: 1000)
    later!
    expect(preview(hours_worked: 65).dig(:deltas, :retirement_payment)).to eq(37.5)
    correction = issue(hours_worked: 65)
    expect(correction.retirement_payment).to eq(37.5)
    expect(employee.ytd_totals_for(2024).reload.retirement).to eq(937.5)
  end
end
