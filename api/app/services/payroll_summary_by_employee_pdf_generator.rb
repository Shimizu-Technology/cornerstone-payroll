# frozen_string_literal: true

require "prawn"
require "prawn/table"

# QuickBooks-style Payroll Summary by Employee.
# The report keeps Cornerstone's richer detail while using the familiar QB
# grouped columns: Hours, Gross pay, Other pay, Employee taxes/deductions,
# Net pay, Employer taxes/contributions, and Total payroll cost.
class PayrollSummaryByEmployeePdfGenerator
  QB_BORDER = "B7BDC7"
  QB_HEADER_BG = "F2F2F2"
  QB_TOTAL_BG = "F7F7F7"
  TEXT = "3B3B3B"
  MUTED = "666666"

  attr_reader :pay_period, :company, :data

  def initialize(pay_period)
    @pay_period = pay_period
    @company = pay_period.company
    @data = QuickbooksPayrollReportData.new(pay_period)
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :landscape, margin: [ 30, 10, 36, 10 ])
    render_header(pdf)
    render_table(pdf)
    render_footer(pdf)
    pdf.render
  end

  def filename
    "payroll_summary_by_employee_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"
  end

  private

  def render_header(pdf)
    pdf.fill_color TEXT
    pdf.font_size(11) { pdf.text company.name, align: :center }
    pdf.move_down 8
    pdf.font_size(17) { pdf.text "Payroll summary by employee report", align: :center }
    pdf.move_down 8
    pdf.font_size(12) { pdf.text data.qb_date_range_label, align: :center }
    pdf.move_down 18
  end

  def render_table(pdf)
    rows = [ header_row, total_row ] + data.items.map { |item| employee_row(item) }

    pdf.table(rows, header: true, width: pdf.bounds.width, column_widths: column_widths, cell_style: { size: 6.5, padding: [ 4, 2 ], overflow: :shrink_to_fit, min_font_size: 4 }) do
      cells.border_color = QB_BORDER
      cells.border_width = 0.6
      cells.padding = [ 4, 2 ]
      cells.size = 6.5
      cells.text_color = TEXT
      row(0).background_color = QB_HEADER_BG
      row(0).font_style = :normal
      row(0).size = 7
      row(1).background_color = QB_TOTAL_BG
      columns(1..7).align = :right
      columns(0).align = :left
      self.header = true
    end
  end

  def header_row
    [
      "Name",
      "Hours",
      "Gross pay",
      "Other pay",
      "Employee taxes & deductions",
      "Net pay",
      "Employer taxes & contributions",
      "Total payroll\ncost"
    ]
  end

  def total_row
    summary = data.total_summary
    pre_tax_lines = data.aggregate_lines(data.items.flat_map { |item| data.pre_tax_retirement_deduction_lines_for(item) })
    after_tax_lines = data.aggregate_lines(data.items.flat_map { |item| data.after_tax_deduction_lines_for(item) })
    tax_lines = aggregate_tax_lines
    employer_contribution_lines = data.aggregate_lines(data.items.flat_map { |item| data.employer_contribution_lines_for(item) })

    [
      "Total",
      lines_cell([ QuickbooksPayrollReportData::Line.new(label: "Gross", hours: summary.total_hours) ] + aggregate_hours_lines),
      gross_cell(summary.gross_pay, aggregate_earnings_lines, pre_tax_lines, data.items.sum { |item| data.employee_adjusted_gross(item) }),
      lines_cell([ QuickbooksPayrollReportData::Line.new(label: "Total", amount: summary.other_pay) ] + aggregate_other_pay_lines),
      employee_taxes_cell(summary.employee_taxes, tax_lines, summary.after_tax_deductions, after_tax_lines),
      money(summary.net_pay),
      employer_cell(
        summary.employer_taxes,
        employer_contribution_lines,
        ss: data.items.sum { |item| item.employer_social_security_tax.to_f },
        medicare: data.items.sum { |item| item.employer_medicare_tax.to_f }
      ),
      money(summary.total_payroll_cost)
    ]
  end

  def employee_row(item)
    pre_tax_lines = data.pre_tax_retirement_deduction_lines_for(item)
    after_tax_lines = data.after_tax_deduction_lines_for(item)
    tax_lines = data.employee_tax_lines_for(item)
    employer_lines = data.employer_contribution_lines_for(item)

    [
      data.qb_employee_name(item.employee),
      lines_cell([ QuickbooksPayrollReportData::Line.new(label: "Gross", hours: item.total_hours.to_f) ]),
      gross_cell(item.gross_pay.to_f, data.earnings_lines_for(item).drop(1), pre_tax_lines, data.employee_adjusted_gross(item)),
      lines_cell([ QuickbooksPayrollReportData::Line.new(label: "Total", amount: data.other_pay_lines_for(item).sum { |line| line.amount.to_f }) ] + data.other_pay_lines_for(item)),
      employee_taxes_cell(data.employee_tax_total(item), tax_lines, data.employee_after_tax_total(item), after_tax_lines),
      money(item.net_pay),
      employer_cell(data.employer_tax_total(item), employer_lines, ss: item.employer_social_security_tax.to_f, medicare: item.employer_medicare_tax.to_f),
      money(data.total_payroll_cost(item))
    ]
  end

  def gross_cell(gross_total, earning_lines, pre_tax_lines, adjusted_gross)
    lines = [ QuickbooksPayrollReportData::Line.new(label: "Gross", amount: gross_total) ]
    lines += earning_lines
    if pre_tax_lines.any?
      lines << QuickbooksPayrollReportData::Line.new(label: "Pre-tax / retirement deductions", amount: pre_tax_lines.sum { |line| line.amount.to_f })
      lines += pre_tax_lines.map { |line| QuickbooksPayrollReportData::Line.new(label: "  #{line.label}", amount: line.amount) }
    end
    lines << QuickbooksPayrollReportData::Line.new(label: "Adjusted gross", amount: adjusted_gross)
    lines_cell(lines, negative_labels: [ "Pre-tax / retirement deductions", *pre_tax_lines.map { |line| "  #{line.label}" } ])
  end

  def employee_taxes_cell(tax_total, tax_lines, after_tax_total, after_tax_lines)
    total = tax_total.to_f + after_tax_total.to_f
    lines = [
      QuickbooksPayrollReportData::Line.new(label: "Total", amount: total),
      QuickbooksPayrollReportData::Line.new(label: "Employee taxes", amount: tax_total)
    ]
    lines += tax_lines.map { |line| QuickbooksPayrollReportData::Line.new(label: "  #{line.label}", amount: line.amount) }
    if after_tax_lines.any?
      lines << QuickbooksPayrollReportData::Line.new(label: "After-tax deductions", amount: after_tax_total)
      lines += after_tax_lines.map { |line| QuickbooksPayrollReportData::Line.new(label: "  #{line.label}", amount: line.amount) }
    end
    lines_cell(lines, negative: true)
  end

  def employer_cell(employer_tax_total, contribution_lines, ss:, medicare:)
    contribution_total = contribution_lines.sum { |line| line.amount.to_f }
    lines = [
      QuickbooksPayrollReportData::Line.new(label: "Total", amount: employer_tax_total.to_f + contribution_total),
      QuickbooksPayrollReportData::Line.new(label: "Employer taxes", amount: employer_tax_total),
      QuickbooksPayrollReportData::Line.new(label: "  Social Security Employer", amount: ss),
      QuickbooksPayrollReportData::Line.new(label: "  Medicare Employer", amount: medicare)
    ]
    if contribution_lines.any?
      lines << QuickbooksPayrollReportData::Line.new(label: "Contributions", amount: contribution_total)
      lines += contribution_lines.map { |line| QuickbooksPayrollReportData::Line.new(label: "  #{line.label}", amount: line.amount) }
    end
    lines_cell(lines)
  end

  def lines_cell(lines, negative: false, negative_labels: [])
    present = lines.select { |line| line.amount.present? || line.hours.present? }
    return "" if present.empty?

    present.map do |line|
      amount = if line.amount.present?
        money(line.amount.to_f, negative: negative || negative_labels.include?(line.label))
      end
      hours = hours_text(line.hours)
      values = [ hours, amount ].compact.join("  ")
      values.present? ? "#{line.label}    #{values}" : line.label
    end.join("\n")
  end

  def aggregate_earnings_lines
    data.aggregate_lines(data.items.flat_map { |item| data.earnings_lines_for(item).drop(1) })
  end

  def aggregate_hours_lines
    aggregate_earnings_lines.select { |line| line.hours.to_f.positive? }
  end

  def aggregate_other_pay_lines
    data.aggregate_lines(data.items.flat_map { |item| data.other_pay_lines_for(item) })
  end

  def aggregate_tax_lines
    data.aggregate_lines(data.items.flat_map { |item| data.employee_tax_lines_for(item) })
  end

  def deduction_amount_for_label(item, label, category)
    data.deduction_contribution_entries_for_item(item)
      .select { |entry| entry.bucket == category && entry.description == label }
      .sum { |entry| entry.employee_amount.to_f }
  end

  def column_widths
    [ 68, 78, 140, 78, 140, 64, 140, 64 ]
  end

  def money(value, negative: false)
    val = value.to_f
    return "$0.00" if val.zero?

    prefix = negative || val.negative? ? "-" : ""
    "#{prefix}$#{format('%.2f', val.abs)}"
  end

  def hours_text(value)
    hours = value.to_f
    return nil unless hours.positive?

    "#{format('%.2f', hours).sub(/\.00\z/, '')}h"
  end

  def render_footer(pdf)
    pdf.repeat(:all) do
      pdf.canvas do
        pdf.fill_color MUTED
        pdf.font_size(8) do
          pdf.draw_text data.generated_at_label, at: [ pdf.bounds.width / 2 - 70, 18 ]
        end
      end
    end
    pdf.number_pages "<page>", at: [ pdf.bounds.right - 20, 18 ], size: 8, align: :right, color: MUTED
  end
end
