# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Generates a Retirement Plans Report PDF showing 401(k) / retirement contributions.
class RetirementPlansReportPdfGenerator
  include PdfFooter

  HEADER_BG   = "2B4090"
  SECTION_BG  = "F0F4FF"
  BORDER_GRAY = "CCCCCC"
  TEXT_DARK   = "1A1A2E"
  TEXT_MUTED  = "666666"

  attr_reader :pay_period, :company

  def initialize(pay_period)
    @pay_period = pay_period
    @company = pay_period.company
  end

  def generate
    items = pay_period.payroll_items
      .includes(:employee)
      .where(voided: false)
      .order("employees.last_name ASC, employees.first_name ASC")

    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :portrait, margin: [36, 36, 50, 36])
    render_document(pdf, items.to_a)
  end

  def filename
    "retirement_plans_report_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"
  end

  private

  def render_document(pdf, items)
    render_header(pdf)

    if items.empty?
      pdf.text "No payroll items found.", style: :italic, color: TEXT_MUTED
      return
    end

    retirement_items = items.select do |item|
      item.retirement_payment.to_f > 0 ||
      item.roth_retirement_payment.to_f > 0 ||
      item.employer_retirement_match.to_f > 0 ||
      item.employer_roth_retirement_match.to_f > 0
    end

    if retirement_items.empty?
      pdf.text "No retirement contributions found for this pay period.", style: :italic, color: TEXT_MUTED
      return
    end

    render_contributions_table(pdf, retirement_items)
    render_summary(pdf, retirement_items)

    render_with_footer(pdf,
      "#{company.name} \u2014 Retirement Plans Report \u2014 #{pay_period.start_date} to #{pay_period.end_date} \u2014 CONFIDENTIAL"
    )
  end

  def render_header(pdf)
    pdf.font_size(16) { pdf.text company.name, style: :bold, color: HEADER_BG }
    pdf.font_size(11) { pdf.text "Retirement Plans Report", color: TEXT_DARK }
    pdf.font_size(9) do
      pdf.text "Pay Period: #{pay_period.start_date.strftime('%b %d, %Y')} – #{pay_period.end_date.strftime('%b %d, %Y')}  |  Pay Date: #{pay_period.pay_date.strftime('%b %d, %Y')}", color: TEXT_MUTED
    end
    pdf.move_down 14
  end

  def render_contributions_table(pdf, items)
    header = [
      "Employee", "Gross Pay", "401(k) Pre-Tax", "401(k) Roth", "Employer Match (Pre-Tax)",
      "Employer Match (Roth)", "Total Employee", "Total Employer", "Grand Total"
    ].map.with_index do |label, idx|
      { content: label, background_color: HEADER_BG, text_color: "FFFFFF",
        font_style: :bold, align: idx.zero? ? :left : :right }
    end

    rows = items.map do |item|
      pre_tax = item.retirement_payment.to_f
      roth = item.roth_retirement_payment.to_f
      emp_match = item.employer_retirement_match.to_f
      roth_match = item.employer_roth_retirement_match.to_f

      [
        { content: item.employee_full_name },
        { content: fmt(item.gross_pay), align: :right },
        { content: fmt(pre_tax), align: :right },
        { content: fmt(roth), align: :right },
        { content: fmt(emp_match), align: :right },
        { content: fmt(roth_match), align: :right },
        { content: fmt(pre_tax + roth), align: :right, font_style: :bold },
        { content: fmt(emp_match + roth_match), align: :right, font_style: :bold },
        { content: fmt(pre_tax + roth + emp_match + roth_match), align: :right, font_style: :bold }
      ]
    end

    totals = totals_row(items)

    pdf.table([header] + rows + [totals],
      width: pdf.bounds.width,
      cell_style: { size: 7, padding: [3, 5], border_color: BORDER_GRAY, overflow: :shrink_to_fit }
    )
    pdf.move_down 12
  end

  def totals_row(items)
    t_pre = items.sum { |i| i.retirement_payment.to_f }
    t_roth = items.sum { |i| i.roth_retirement_payment.to_f }
    t_emp = items.sum { |i| i.employer_retirement_match.to_f }
    t_roth_match = items.sum { |i| i.employer_roth_retirement_match.to_f }

    [
      { content: "TOTALS (#{items.size} employees)", font_style: :bold, background_color: SECTION_BG },
      { content: fmt(items.sum { |i| i.gross_pay.to_f }), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t_pre), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t_roth), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t_emp), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t_roth_match), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t_pre + t_roth), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t_emp + t_roth_match), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t_pre + t_roth + t_emp + t_roth_match), align: :right, font_style: :bold, background_color: SECTION_BG }
    ]
  end

  def render_summary(pdf, items)
    total_employee = items.sum { |i| i.retirement_payment.to_f + i.roth_retirement_payment.to_f }
    total_employer = items.sum { |i| i.employer_retirement_match.to_f + i.employer_roth_retirement_match.to_f }

    pdf.font_size(10) do
      pdf.text "Total to be deducted from bank account for retirement provider:", style: :bold
      pdf.text "Employee contributions: #{fmt(total_employee)}"
      pdf.text "Employer contributions: #{fmt(total_employer)}"
      pdf.text "Combined total: #{fmt(total_employee + total_employer)}", style: :bold, color: HEADER_BG
    end
  end

  def fmt(value)
    "$#{format('%.2f', value.to_f)}"
  end
end
