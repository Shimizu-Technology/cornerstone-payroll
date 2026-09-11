# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe PayrollRetirementTotals do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) { create(:payroll_item, employee: employee, pay_period: period, retirement_payment: 20, roth_retirement_payment: 10) }

  def deduction(label:, amount:, category: "pre_tax", group: "401k_pre_tax", sub_category: "retirement")
    type = DeductionType.create!(company: company, name: label, category: category, sub_category: sub_category, reporting_group: group)
    item.payroll_item_deductions.create!(deduction_type: type, label: label, amount: amount, category: category, reporting_group: group)
  end

  before do
    deduction(label: "Fixed 401(k)", amount: 900.00)
    deduction(label: "Roth 401(k)", amount: 100, category: "post_tax", group: "401k_after_tax")
    deduction(label: "Employer 401(k)", amount: 200, category: "employer_contribution")
    deduction(label: "Health", amount: 55, group: nil, sub_category: "insurance")
    deduction(label: "Separate pension", amount: 80, group: "retirement_other")
    field = create(:payroll_field_definition, company: company, name: "Extra 401(k)", kind: "deduction",
                   tax_treatment: "pre_tax_deduction", category: "retirement", reporting_group: "401k_pre_tax")
    create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: field, amount: 25, reporting_group: "401k_pre_tax")
    deduction(label: "Extra 401(k)", amount: 25).deduction_type.update!(name: "Payroll Field: Extra 401(k)")
  end

  it "counts saved fixed and flexible contributions once, with employer and unrelated plans excluded" do
    expect(described_class.for_item(item.reload)).to eq(retirement: 945.00.to_d, roth_retirement: 110.to_d)
    report = QuickbooksPayrollReportData.new(period).retirement_rows
    expect(report.select { |row| row.group == "401k_pre_tax" }.sum(&:employee_amount)).to eq(945.00)
  end

  it "includes the same amounts in scoped and batch YTD without modifying saved snapshots" do
    snapshot = item.reload.attributes
    expect(employee.ytd_totals_through(year: 2024, pay_date: period.pay_date, pay_period_id: period.id)).to include(
      retirement: 945.00.to_d, roth_retirement: 110.to_d
    )
    expect(described_class.for_scope_by_employee(PayrollItem.where(id: item.id))).to eq(
      employee.id => { retirement: 945.00.to_d, roth_retirement: 110.to_d }
    )
    expect(item.reload.attributes).to eq(snapshot)
    item.update_columns(voided: true)
    expect(employee.ytd_totals_through(year: 2024, pay_date: period.pay_date, pay_period_id: period.id)).to include(retirement: 0, roth_retirement: 0)
  end

  it "adds and reverses every contribution symmetrically in the commit ledger" do
    ytd = employee.ytd_totals_for(2024)
    ytd.add_payroll_item!(item)
    expect(ytd.reload).to have_attributes(retirement: 945.00.to_d, roth_retirement: 110.to_d)
    ytd.subtract_payroll_item!(item)
    expect(ytd.reload).to have_attributes(retirement: 0.to_d, roth_retirement: 0.to_d)
  end

  it "puts the current contributions and earlier saved paycheck into the calculated YTD snapshot" do
    next_period = create(:pay_period, company: company, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 28), pay_date: Date.new(2024, 2, 2))
    next_item = build(:payroll_item, employee: employee, pay_period: next_period, retirement_payment: 30, roth_retirement_payment: 15)
    PayrollCalculator.new(employee, next_item).send(:update_ytd_on_item)
    expect(next_item).to have_attributes(ytd_retirement: 975.00.to_d, ytd_roth_retirement: 125.to_d)
  end

  it "shows fixed and flexible 401(k) once on the pay stub and excludes employer money" do
    item.update!(ytd_retirement: 945.00, ytd_roth_retirement: 110, total_deductions: 1190.00)
    generator = PayStubGenerator.new(item.reload)
    text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")
    retirement_line = text.lines.find { |line| line.include?("401(k) Retirement") }
    roth_line = text.lines.find { |line| line.include?("Roth 401(k)") }
    expect(retirement_line.scan("$945.00").length).to eq(2)
    expect(roth_line.scan("$110.00").length).to eq(2)
    expect(text).not_to include("Extra 401(k)")
    expect(text).to include("Separate pension")
    expect(generator.send(:ytd_payroll_field_deductions_total)).to eq(0)
    # Insurance is a legacy aggregate on real calculated rows; this saved fixture
    # deliberately omits that aggregate so only 401(k) and the other plan are here.
    expect(generator.send(:ytd_total_deductions).round(2)).to eq(1135.00)
  end

  it "preserves signed built-in correction amounts" do
    item.update_columns(retirement_payment: -20, roth_retirement_payment: -10)
    expect(described_class.for_item(item.reload)).to eq(retirement: 905.00.to_d, roth_retirement: 90.to_d)
  end
end
