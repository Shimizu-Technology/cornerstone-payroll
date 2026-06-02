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
    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :landscape, margin: [ 36, 36, 50, 36 ])
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
    render_payroll_fields_summary(pdf)
    render_employee_table(pdf)

    pp = report[:pay_period] || {}
    company_name = report.dig(:meta, :company_name).presence
    render_with_footer(pdf,
      [ company_name, "Payroll Register", "Pay Period: #{pp[:start_date]} \u2013 #{pp[:end_date]}", "Pay Date: #{pp[:pay_date]}", "CONFIDENTIAL, FOR INTERNAL USE ONLY" ].compact.join(" \u2014 "),
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
      company_name = report.dig(:meta, :company_name)
      subtitle = [ company_name, "Pay Period: #{pp[:start_date]} – #{pp[:end_date]}", "Pay Date: #{pp[:pay_date]}", "Status: #{pp[:status]&.capitalize}" ].compact.join("  |  ")
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
      [ "Description",   meta[:report_description].to_s ],
      [ "Generated At",  meta[:generated_at].to_s ]
    ].reject { |_, value| value.blank? }

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
    rows.insert(2, [ "Custom Earnings", fmt(s[:total_custom_earnings]) ]) if custom_earnings_column?
    rows.insert(-3, [ "Custom Deductions", fmt(s[:total_custom_deductions]) ]) if custom_deductions_column?

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

  def render_payroll_fields_summary(pdf)
    rows = payroll_field_total_rows
    return if rows.empty?

    pdf.start_new_page if pdf.cursor < 120
    pdf.font_size(11) { pdf.text "Payroll Fields", style: :bold }
    pdf.move_down 4

    table_data = [[ "Treatment", "Field", "Employee Paid", "Employer Paid", "Amount" ]] + rows
    pdf.table(table_data, header: true, width: pdf.bounds.width) do
      row(0).font_style = :bold
      row(0).background_color = HEADER_BG
      row(0).text_color = "FFFFFF"
      cells.size = 8
      cells.padding = [ 3, 5 ]
      columns(2..4).align = :right
    end
    pdf.move_down 14
  end

  def payroll_field_total_rows
    entries = Array(report[:employees]).flat_map { |emp| Array(emp[:payroll_field_entries]) } +
      Array(report[:contractors]).flat_map { |emp| Array(emp[:payroll_field_entries]) }
    entries.group_by { |entry| [ entry[:tax_treatment], entry[:label], entry[:employee_paid], entry[:employer_paid] ] }
      .sort_by { |key, _| key.map(&:to_s) }
      .map do |(treatment, label, employee_paid, employer_paid), grouped|
        [ treatment.to_s.humanize, label, employee_paid ? "Yes" : "No", employer_paid ? "Yes" : "No", fmt(grouped.sum { |entry| entry[:amount].to_f }) ]
      end
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

    columns = employee_table_columns
    header = columns.map do |column|
      {
        content: column[:label],
        background_color: HEADER_BG,
        text_color: "FFFFFF",
        font_style: :bold,
        align: column[:align]
      }.compact
    end

    rows = employees.map { |emp| employee_table_row(emp, columns) }

    # Totals footer
    s = report[:summary] || {}
    totals_row = columns.map { |column| total_table_cell(column, s) }

    table_data = [ header ] + rows + [ totals_row ]

    page_width = pdf.bounds.width
    total_weight = columns.sum { |column| column[:weight] }
    col_widths = columns.map { |column| page_width * (column[:weight] / total_weight.to_f) }
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

  def employee_table_row(emp, columns)
    columns.map do |column|
      {
        content: employee_table_value(emp, column[:key]),
        align: column[:align]
      }.compact
    end
  end

  def employee_table_columns
    columns = [
      { key: :employee_name, label: "Employee", weight: 13 },
      { key: :employment_type, label: "Type", weight: 5 },
      { key: :hours_worked, label: "Hours", weight: 5, align: :right },
      { key: :overtime_hours, label: "OT Hrs", weight: 5, align: :right },
      { key: :gross_pay, label: "Gross Pay", weight: 8, align: :right },
      { key: :withholding_tax, label: "Withholding", weight: 8, align: :right },
      { key: :additional_withholding, label: "Addtl W/H", weight: 7, align: :right },
      { key: :social_security_tax, label: "Soc Sec", weight: 7, align: :right },
      { key: :medicare_tax, label: "Medicare", weight: 7, align: :right },
      { key: :retirement_payment, label: "Retirement", weight: 7, align: :right },
      { key: :total_deductions, label: "Deductions", weight: 8, align: :right },
      { key: :net_pay, label: "Net Pay", weight: 8, align: :right },
      { key: :check_number, label: "Check #", weight: 8 }
    ]
    columns.insert(5, { key: :custom_earnings_total, label: "Custom Earn", weight: 7, align: :right }) if custom_earnings_column?
    columns.insert(-4, { key: :custom_deductions_total, label: "Custom Ded", weight: 7, align: :right }) if custom_deductions_column?
    columns
  end

  def employee_table_value(emp, key)
    case key
    when :employee_name, :employment_type, :check_number
      emp[key].to_s
    when :hours_worked, :overtime_hours
      emp[key].to_f.to_s
    else
      fmt(emp[key])
    end
  end

  def total_table_cell(column, summary)
    content = case column[:key]
    when :employee_name
      "TOTALS"
    when :gross_pay
      fmt(summary[:total_gross])
    when :custom_earnings_total
      fmt(summary[:total_custom_earnings])
    when :withholding_tax
      fmt(summary[:total_withholding])
    when :additional_withholding
      fmt(summary[:total_additional_withholding])
    when :social_security_tax
      fmt(summary[:total_social_security])
    when :medicare_tax
      fmt(summary[:total_medicare])
    when :retirement_payment
      fmt(summary[:total_retirement])
    when :custom_deductions_total
      fmt(summary[:total_custom_deductions])
    when :total_deductions
      fmt(summary[:total_deductions])
    when :net_pay
      fmt(summary[:total_net])
    else
      ""
    end

    {
      content: content,
      align: column[:align],
      font_style: content.present? ? :bold : nil,
      background_color: SECTION_BG
    }.compact
  end

  def custom_earnings_column?
    summary = report[:summary] || {}
    summary[:total_custom_earnings].to_f.positive? ||
      Array(report[:employees]).any? { |emp| emp[:custom_earnings_total].to_f.positive? }
  end

  def custom_deductions_column?
    summary = report[:summary] || {}
    summary[:total_custom_deductions].to_f.positive? ||
      Array(report[:employees]).any? { |emp| emp[:custom_deductions_total].to_f.positive? }
  end

  # ─── Helpers ────────────────────────────────────────────────────────────────

  def fmt(value)
    format("$%.2f", value.to_f)
  end
end
