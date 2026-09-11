# frozen_string_literal: true

# Uses the same saved components as reports, including voided checks. Never
# reads current employee defaults to explain a previously calculated paycheck.
class PayrollItemDisclosure
  def initialize(item)
    @item = item
    @report = QuickbooksPayrollReportData.new(item.pay_period)
  end

  def as_json(*)
    deductions = @report.deduction_contribution_entries_for_item(@item)
    other_pay = @report.other_pay_lines_for(@item)
    tax = PayrollTaxSummary.new(@item)
    {
      earnings: lines(@report.earnings_lines_for(@item).drop(1)),
      other_pay: lines(other_pay),
      taxes: tax.lines,
      deductions: deductions.filter_map do |entry|
        next if entry.employee_amount.to_d.zero?

        { label: entry.description, amount: entry.employee_amount, source: entry.source,
          treatment: entry.bucket }
      end,
      employer_contributions: deductions.filter_map do |entry|
        next if entry.company_amount.to_d.zero?

        { label: entry.description, amount: entry.company_amount, source: entry.source }
      end,
      reconciliation: {
        gross_pay: @item.gross_pay.to_f,
        other_pay: other_pay.sum { |line| line.amount.to_d }.round(2).to_f,
        employee_taxes: tax.total.to_f,
        other_deductions: (@item.total_deductions.to_d - tax.total).round(2).to_f,
        net_pay: @item.net_pay.to_f
      }
    }
  end

  private

  def lines(entries)
    entries.map { |entry| { label: entry.label, amount: entry.amount, source: entry.source } }
  end
end
