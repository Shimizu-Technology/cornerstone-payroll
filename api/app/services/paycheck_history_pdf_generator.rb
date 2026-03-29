# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Generates a Paycheck History PDF showing every check issued for a pay period.
class PaycheckHistoryPdfGenerator
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
      .order("employees.last_name ASC, employees.first_name ASC")

    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :landscape, margin: [36, 36, 50, 36])
    render_document(pdf, items.to_a)
  end

  def filename
    "paycheck_history_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"
  end

  private

  def render_document(pdf, items)
    render_header(pdf)

    if items.empty?
      pdf.text "No paychecks found.", style: :italic, color: TEXT_MUTED
      return
    end

    render_summary(pdf, items)
    render_checks_table(pdf, items)

    render_with_footer(pdf,
      "#{company.name} \u2014 Paycheck History \u2014 #{pay_period.start_date} to #{pay_period.end_date} \u2014 CONFIDENTIAL"
    )
  end

  def render_header(pdf)
    pdf.font_size(16) { pdf.text company.name, style: :bold, color: HEADER_BG }
    pdf.font_size(11) { pdf.text "Paycheck History", color: TEXT_DARK }
    pdf.font_size(9) do
      pdf.text "Pay Period: #{pay_period.start_date.strftime('%b %d, %Y')} – #{pay_period.end_date.strftime('%b %d, %Y')}  |  Pay Date: #{pay_period.pay_date.strftime('%b %d, %Y')}", color: TEXT_MUTED
    end
    pdf.move_down 12
  end

  def render_summary(pdf, items)
    active = items.reject(&:voided?)
    voided = items.select(&:voided?)

    pdf.font_size(10) do
      pdf.text "Total Checks: #{active.size}  |  Voided: #{voided.size}  |  Total Net Pay: #{fmt(active.sum { |i| i.net_pay.to_f })}", style: :bold
    end
    pdf.move_down 8
  end

  def render_checks_table(pdf, items)
    header = [
      "Check #", "Employee", "Type", "Gross Pay", "FIT", "SS", "Medicare",
      "Retirement", "Other Ded.", "Total Ded.", "Net Pay", "Status"
    ].map do |label|
      { content: label, background_color: HEADER_BG, text_color: "FFFFFF",
        font_style: :bold, align: label == "Employee" || label == "Type" || label == "Status" ? :left : :right }
    end

    rows = items.map do |item|
      status = item.check_status || "—"
      other_ded = item.total_deductions.to_f - item.withholding_tax.to_f -
                  item.social_security_tax.to_f - item.medicare_tax.to_f -
                  item.retirement_payment.to_f - item.roth_retirement_payment.to_f
      [
        { content: item.check_number || "—" },
        { content: item.employee_full_name },
        { content: item.employment_type.capitalize },
        { content: fmt(item.gross_pay), align: :right },
        { content: fmt(item.withholding_tax), align: :right },
        { content: fmt(item.social_security_tax), align: :right },
        { content: fmt(item.medicare_tax), align: :right },
        { content: fmt(item.retirement_payment.to_f + item.roth_retirement_payment.to_f), align: :right },
        { content: fmt([other_ded, 0].max), align: :right },
        { content: fmt(item.total_deductions), align: :right },
        { content: fmt(item.net_pay), align: :right },
        { content: status.capitalize, font_style: item.voided? ? :bold_italic : :normal,
          text_color: item.voided? ? "CC0000" : TEXT_DARK }
      ]
    end

    # Totals
    active = items.reject(&:voided?)
    totals = [
      { content: "TOTALS", font_style: :bold, background_color: SECTION_BG },
      { content: "#{active.size} checks", background_color: SECTION_BG },
      { content: "", background_color: SECTION_BG },
      { content: fmt(active.sum { |i| i.gross_pay.to_f }), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(active.sum { |i| i.withholding_tax.to_f }), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(active.sum { |i| i.social_security_tax.to_f }), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(active.sum { |i| i.medicare_tax.to_f }), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(active.sum { |i| i.retirement_payment.to_f + i.roth_retirement_payment.to_f }), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: "", background_color: SECTION_BG },
      { content: fmt(active.sum { |i| i.total_deductions.to_f }), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(active.sum { |i| i.net_pay.to_f }), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: "", background_color: SECTION_BG }
    ]

    pdf.table([header] + rows + [totals],
      width: pdf.bounds.width,
      cell_style: { size: 7, padding: [3, 4], border_color: BORDER_GRAY, overflow: :shrink_to_fit }
    )
  end

  def fmt(value)
    "$#{format('%.2f', value.to_f)}"
  end
end
