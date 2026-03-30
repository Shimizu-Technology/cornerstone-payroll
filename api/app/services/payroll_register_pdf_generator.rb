# frozen_string_literal: true

require "prawn"
require "prawn/table"

# PayrollRegisterPdfGenerator
#
# Generates a Prawn PDF payroll register from report data.
# Layout: pay period metadata → summary totals → employee detail table.
#
# Usage:
#   report_data = build_payroll_register_data(pay_period)
#   generator   = PayrollRegisterPdfGenerator.new(report_data)
#   send_data generator.generate, filename: generator.filename, type: "application/pdf", disposition: "attachment"
#
class PayrollRegisterPdfGenerator
  include PdfFooter

  HEADER_BG   = "2B4090"
  SECTION_BG  = "F0F4FF"
  BORDER_GRAY = "CCCCCC"
  TEXT_DARK   = "1A1A2E"
  TEXT_MUTED  = "666666"

  attr_reader :report

  def initialize(report_data)
    @report = report_data
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :landscape, margin: [36, 36, 50, 36])
    render_document(pdf)
  end

  def filename
    pp = report[:pay_period] || {}
    start_d = pp[:start_date].to_s.gsub(/[^0-9\-]/, "")
    end_d   = pp[:end_date].to_s.gsub(/[^0-9\-]/, "")
    if start_d.present? && end_d.present?
      "payroll_register_#{start_d}_to_#{end_d}.pdf"
    else
      "payroll_register_unknown_period.pdf"
    end
  end

  private

  def render_document(pdf)
    render_header(pdf)
    render_pay_period_block(pdf)
    render_summary_block(pdf)
    render_employee_table(pdf)

    pp = report[:pay_period] || {}
    render_with_footer(pdf,
      "Payroll Register \u2014 Pay Period: #{pp[:start_date]} \u2013 #{pp[:end_date]} \u2014 Pay Date: #{pp[:pay_date]} \u2014 CONFIDENTIAL, FOR INTERNAL USE ONLY",
      font_size: 7
    )
  end

  # ─── Header ────────────────────────────────────────────────────────────────

  def render_header(pdf)
    pdf.fill_color HEADER_BG
    pdf.fill_rectangle [ pdf.bounds.left, pdf.bounds.top ], pdf.bounds.width, 52
    pdf.fill_color "FFFFFF"

    pdf.bounding_box([ pdf.bounds.left + 12, pdf.bounds.top - 10 ], width: pdf.bounds.width - 24) do
      pdf.font_size(18) { pdf.text "Payroll Register", style: :bold }
      pp = report[:pay_period] || {}
      subtitle = "Pay Period: #{pp[:start_date]} – #{pp[:end_date]}  |  Pay Date: #{pp[:pay_date]}  |  Status: #{pp[:status]&.capitalize}"
      pdf.font_size(10) { pdf.text subtitle }
    end

    pdf.fill_color TEXT_DARK
    pdf.move_down 60
  end

  # ─── Pay Period Block ───────────────────────────────────────────────────────

  def render_pay_period_block(pdf)
    pp     = report[:pay_period] || {}
    meta   = report[:meta] || {}

    pdf.font_size(11) { pdf.text "Pay Period Information", style: :bold }
    pdf.move_down 4

    rows = [
      [ "Pay Period ID", pp[:id].to_s ],
      [ "Start Date",    pp[:start_date].to_s ],
      [ "End Date",      pp[:end_date].to_s ],
      [ "Pay Date",      pp[:pay_date].to_s ],
      [ "Status",        pp[:status].to_s.capitalize ],
      [ "Generated At",  meta[:generated_at].to_s ]
    ]

    table_data = rows.map { |k, v| [ { content: k, font_style: :bold }, v ] }

    pdf.table(table_data,
      width: pdf.bounds.width / 2,
      cell_style: { size: 9, padding: [ 4, 8 ], border_color: BORDER_GRAY }
    ) do
      column(0).background_color = SECTION_BG
      column(0).width = 140
      column(0).text_color = TEXT_DARK
      column(1).text_color = TEXT_DARK
    end

    pdf.fill_color TEXT_DARK
    pdf.move_down 14
  end

  # ─── Summary Block ──────────────────────────────────────────────────────────

  def render_summary_block(pdf)
    s = report[:summary] || {}

    pdf.font_size(11) { pdf.text "Summary Totals", style: :bold }
    pdf.move_down 4

    rows = [
      [ "Employee Count",       s[:employee_count].to_s ],
      [ "Total Gross Pay",      fmt(s[:total_gross]) ],
      [ "Total Withholding",    fmt(s[:total_withholding]) ],
      [ "Total Social Security", fmt(s[:total_social_security]) ],
      [ "Total Medicare",       fmt(s[:total_medicare]) ],
      [ "Total Retirement",     fmt(s[:total_retirement]) ],
      [ "Total Deductions",     fmt(s[:total_deductions]) ],
      [ "Total Net Pay",        fmt(s[:total_net]) ]
    ]

    table_data = rows.map { |k, v|
      [ { content: k, font_style: :bold }, { content: v, align: :right } ]
    }

    pdf.table(table_data,
      width: pdf.bounds.width / 2,
      cell_style: { size: 9, padding: [ 4, 8 ], border_color: BORDER_GRAY }
    ) do
      column(0).background_color = SECTION_BG
      column(0).width = 200
      column(0).text_color = TEXT_DARK
      column(1).text_color = TEXT_DARK
    end

    pdf.fill_color TEXT_DARK
    pdf.move_down 14
  end

  # ─── Employee Table ─────────────────────────────────────────────────────────

  def render_employee_table(pdf)
    employees = report[:employees] || []

    pdf.start_new_page if pdf.cursor < 140
    pdf.font_size(11) { pdf.text "Employee Detail", style: :bold }
    pdf.move_down 6

    if employees.empty?
      pdf.font_size(9) { pdf.text "No payroll items found for this pay period.", style: :italic, color: TEXT_MUTED }
      return
    end

    header = [
      { content: "Employee",     background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold },
      { content: "Type",         background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold },
      { content: "Hours",        background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "OT Hrs",       background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Gross Pay",    background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Withholding",  background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Addtl W/H",   background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Soc Sec",      background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Medicare",     background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Retirement",   background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Deductions",   background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Net Pay",      background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Check #",      background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold }
    ]

    rows = employees.map { |emp| employee_table_row(emp) }

    # Totals footer
    s = report[:summary] || {}
    totals_row = [
      { content: "TOTALS", font_style: :bold, background_color: SECTION_BG },
      { content: "", background_color: SECTION_BG },
      { content: "", background_color: SECTION_BG },
      { content: "", background_color: SECTION_BG },
      { content: fmt(s[:total_gross]),                  align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(s[:total_withholding]),             align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(s[:total_additional_withholding]),  align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(s[:total_social_security]),         align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(s[:total_medicare]),                align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(s[:total_retirement]),              align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(s[:total_deductions]),              align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(s[:total_net]),                     align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: "", background_color: SECTION_BG }
    ]

    table_data = [ header ] + rows + [ totals_row ]

    page_width = pdf.bounds.width
    width_fractions = [
      0.13,      # Employee
      0.05,      # Type
      0.05,      # Hours
      0.05,      # OT Hrs
      0.08,      # Gross
      0.075,     # Withholding
      0.065,     # Addtl W/H
      0.075,     # Soc Sec
      0.07,      # Medicare
      0.07,      # Retirement
      0.075,     # Deductions
      0.085,     # Net Pay
      0.085      # Check #
    ]
    col_widths = width_fractions.map { |fraction| page_width * fraction }
    # Ensure widths sum to exactly page_width (float drift safety)
    col_widths[-1] = page_width - col_widths[0..-2].sum

    pdf.table(
      table_data,
      width: page_width,
      column_widths: col_widths,
      cell_style: {
        size: 7,
        padding: [ 3, 4 ],
        border_color: BORDER_GRAY,
        overflow: :shrink_to_fit
      }
    ) do
      row(0).height = 22
    end

    pdf.fill_color TEXT_DARK
  end

  def employee_table_row(emp)
    [
      { content: emp[:employee_name].to_s },
      { content: emp[:employment_type].to_s },
      { content: emp[:hours_worked].to_f.to_s, align: :right },
      { content: emp[:overtime_hours].to_f.to_s, align: :right },
      { content: fmt(emp[:gross_pay]),               align: :right },
      { content: fmt(emp[:withholding_tax]),          align: :right },
      { content: fmt(emp[:additional_withholding]),   align: :right },
      { content: fmt(emp[:social_security_tax]),      align: :right },
      { content: fmt(emp[:medicare_tax]),             align: :right },
      { content: fmt(emp[:retirement_payment]),       align: :right },
      { content: fmt(emp[:total_deductions]),         align: :right },
      { content: fmt(emp[:net_pay]),                  align: :right },
      { content: emp[:check_number].to_s }
    ]
  end

  # ─── Helpers ────────────────────────────────────────────────────────────────

  def fmt(value)
    format("$%.2f", value.to_f)
  end
end
