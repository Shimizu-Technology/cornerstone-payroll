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
    data.review_warnings.map { |warning| warning[:message] }.uniq.each do |message|
      pdf.text "Review required: #{message}", size: 10
      pdf.move_down 8
    end
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
    pdf.font_size(10) { pdf.text "Pay date: #{data.pay_date_label} | Work period: #{data.pay_period_label}", align: :center }
    pdf.move_down 18
  end

  def render_table(pdf)
    render_worker_summary(pdf, total_row)
    data.items.each { |item| render_worker_summary(pdf, employee_row(item)) }
  end

  def render_worker_summary(pdf, values)
    pdf.start_new_page if pdf.cursor < 230
    # One labeled line per row keeps labels and amounts readable, even with many
    # earning rates or payroll fields. Worker identity repeats after pagination.
    rows = [ [ values.first, "Payroll detail", "Hours / amount" ] ]
    header_row.drop(1).zip(values.drop(1)).each do |section, detail|
      detail.to_s.split("\n").each_with_index do |line, index|
        parts = line.split(/ {4,}/, 2)
        label, amount = parts.length == 2 ? parts : [ "", line ]
        rows << [ index.zero? ? section.tr("\n", " ") : "", label.strip, amount ]
      end
    end
    pdf.table(rows, header: true, width: pdf.bounds.width,
      column_widths: [ 155, pdf.bounds.width - 295, 140 ],
      cell_style: { size: 9, padding: [ 4, 6 ], border_color: QB_BORDER,
        border_width: 0.5, disable_wrap_by_char: true }) do
      row(0).background_color = QB_HEADER_BG
      row(0).font_style = :bold
      column(0).background_color = QB_TOTAL_BG
      column(2).align = :right
    end
    pdf.move_down 16
  end

  def header_row
    [
      "Name",
      "Combined hours",
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
      lines_cell([ QuickbooksPayrollReportData::Line.new(label: "Total hours", hours: summary.total_hours) ] + aggregate_hours_lines),
      gross_cell(summary.gross_pay, aggregate_earnings_lines, pre_tax_lines, data.items.sum { |item| data.employee_adjusted_gross(item) }),
      lines_cell([ QuickbooksPayrollReportData::Line.new(label: "Total", amount: summary.other_pay) ] + aggregate_other_pay_lines, hide_zero_hours: true),
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
      lines_cell([ QuickbooksPayrollReportData::Line.new(label: "Total hours", hours: item.total_hours.to_f) ]),
      gross_cell(item.gross_pay.to_f, employee_earnings_lines(item), pre_tax_lines, data.employee_adjusted_gross(item)),
      lines_cell([ QuickbooksPayrollReportData::Line.new(label: "Total", amount: data.other_pay_lines_for(item).sum { |line| line.amount.to_f }) ] + data.other_pay_lines_for(item), hide_zero_hours: true),
      employee_taxes_cell(data.employee_tax_total(item), tax_lines, data.employee_after_tax_total(item), after_tax_lines),
      money(item.net_pay),
      employer_cell(data.employer_tax_total(item), employer_lines, ss: item.employer_social_security_tax.to_f, medicare: item.employer_medicare_tax.to_f),
      money(data.total_payroll_cost(item))
    ]
  end

  def employee_earnings_lines(item)
    data.earnings_lines_for(item).drop(1).map do |line|
      rates = item.payroll_item_earnings.select { |earning| earning.label == line.label && earning.rate.present? }.map do |earning|
        unit = %w[regular overtime holiday pto].include?(earning.category) ? "/hour" : " saved rate"
        "#{money(earning.rate)}#{unit}"
      end.uniq
      label = rates.any? ? "#{line.label} (#{rates.join(', ')})" : line.label
      QuickbooksPayrollReportData::Line.new(label: label, amount: line.amount, hours: line.hours)
    end
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

  def lines_cell(lines, negative: false, negative_labels: [], hide_zero_hours: false)
    present = lines.select { |line| line.amount.present? || line.hours.present? }
    return "" if present.empty?

    present.map do |line|
      amount = if line.amount.present?
        money(line.amount.to_f, negative: negative || negative_labels.include?(line.label))
      end
      hours = hours_text(line.hours) unless hide_zero_hours && line.hours.to_f.zero?
      values = [ hours, amount ].compact.join("  ")
      values.present? ? "#{line.label}    #{values}" : line.label
    end.join("\n")
  end

  def aggregate_earnings_lines
    data.aggregate_lines(data.items.flat_map { |item| data.earnings_lines_for(item).drop(1) })
  end

  def aggregate_hours_lines
    aggregate_earnings_lines.select { |line| line.hours.to_f.nonzero? }.map do |line|
      QuickbooksPayrollReportData::Line.new(label: line.label, hours: line.hours)
    end
  end

  def aggregate_other_pay_lines
    data.items.flat_map { |item| data.other_pay_lines_for(item) }.group_by(&:label).map do |label, lines|
      hours = lines.sum { |line| line.hours.to_f }
      QuickbooksPayrollReportData::Line.new(label: label, amount: lines.sum { |line| line.amount.to_f },
        hours: hours.zero? ? nil : hours)
    end.sort_by(&:label)
  end

  def aggregate_tax_lines
    data.aggregate_lines(data.items.flat_map { |item| data.employee_tax_lines_for(item) })
  end

  def deduction_amount_for_label(item, label, category)
    data.deduction_contribution_entries_for_item(item)
      .select { |entry| entry.bucket == category && entry.description == label }
      .sum { |entry| entry.employee_amount.to_f }
  end

  def money(value, negative: false)
    val = value.to_f
    return "$0.00" if val.zero?

    val = -val if negative
    prefix = val.negative? ? "-" : ""
    "#{prefix}$#{format('%.2f', val.abs)}"
  end

  def hours_text(value)
    hours = value.to_f
    return nil if value.nil?

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
    pdf.number_pages "<page>", at: [ pdf.bounds.right - 20, -12 ], size: 8, align: :right, color: MUTED
  end
end
