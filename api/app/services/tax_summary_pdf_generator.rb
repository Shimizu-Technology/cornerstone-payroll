# frozen_string_literal: true

require "prawn"
require "prawn/table"

# TaxSummaryPdfGenerator
#
# Generates a Prawn PDF tax summary from report data.
# Layout: period info → totals breakdown table.
#
# Usage:
#   report_data = build_tax_summary_data(year, quarter)
#   generator   = TaxSummaryPdfGenerator.new(report_data)
#   send_data generator.generate, filename: generator.filename, type: "application/pdf", disposition: "attachment"
#
class TaxSummaryPdfGenerator
  include PdfFooter

  HEADER_BG    = "2B4090"
  SECTION_BG   = "F0F4FF"
  HIGHLIGHT_BG = "E8F5E9"
  BORDER_GRAY  = "CCCCCC"
  TEXT_DARK    = "1A1A2E"
  TEXT_MUTED   = "666666"

  attr_reader :report

  def initialize(report_data)
    @report = report_data
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", margin: [ 36, 36, 50, 36 ])
    render_document(pdf)
  end

  def filename
    period  = report[:period] || {}
    token = if period[:custom]
      "#{period[:start_date]}_to_#{period[:end_date]}"
    else
      [ period[:year] || "unknown", ("q#{period[:quarter]}" if period[:quarter]) ].compact.join("_")
    end
    "tax_summary_#{token}.pdf"
  end

  private

  def render_document(pdf)
    render_header(pdf)
    render_period_block(pdf)
    render_totals_block(pdf)
    render_payroll_fields_block(pdf)

    period = report[:period] || {}
    quarter_label = period_label(period)
    company_name = report.dig(:meta, :company_name).presence
    render_with_footer(pdf,
      [ company_name, "Tax Summary", quarter_label, "CONFIDENTIAL, FOR INTERNAL USE ONLY" ].compact.join(" \u2014 "),
      font_size: 7
    )
  end

  # ─── Header ────────────────────────────────────────────────────────────────

  def render_header(pdf)
    period = report[:period] || {}
    quarter_label = period_label(period)

    pdf.fill_color HEADER_BG
    pdf.fill_rectangle [ pdf.bounds.left, pdf.bounds.top ], pdf.bounds.width, 52
    pdf.fill_color "FFFFFF"

    pdf.bounding_box([ pdf.bounds.left + 12, pdf.bounds.top - 10 ], width: pdf.bounds.width - 24) do
      pdf.font_size(18) { pdf.text "Tax Withholding Summary", style: :bold }
      subtitle = [ report.dig(:meta, :company_name), quarter_label, "Guam Payroll Tax Summary for Quarterly Filing Preparation" ].compact.join(" — ")
      pdf.font_size(10) { pdf.text subtitle }
    end

    pdf.fill_color TEXT_DARK
    pdf.move_down 60
  end

  # ─── Period Info Block ──────────────────────────────────────────────────────

  def render_period_block(pdf)
    period = report[:period] || {}
    quarter_label = period[:quarter] ? "Q#{period[:quarter]}" : (period[:custom] ? "Custom range" : "Full Year")

    pdf.font_size(11) { pdf.text "Period Information", style: :bold }
    pdf.move_down 4

    rows = [
      [ "Reporting Basis",         "Pay date" ],
      [ "Period",                  period_label(period) ],
      [ "Tax Year",                period[:year].to_s ],
      [ "Quarter",                 quarter_label ],
      [ "Period Start",            period[:start_date].to_s ],
      [ "Period End",              period[:end_date].to_s ],
      [ "Description",             report.dig(:meta, :report_description).to_s ],
      [ "Pay Periods Included",    report[:pay_periods_included].to_s ],
      [ "Employees with Payroll",  report[:employee_count].to_s ]
    ].reject { |_, value| value.blank? }

    table_data = rows.map { |k, v| [ { content: k, font_style: :bold }, v ] }

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
    pdf.move_down 18
  end

  # ─── Totals Block ───────────────────────────────────────────────────────────

  def render_totals_block(pdf)
    totals = report[:totals] || {}

    pdf.font_size(11) { pdf.text "Tax Withholding Breakdown", style: :bold }
    pdf.move_down 4

    rows = [
      [ "Gross Wages",                        fmt(totals[:gross_wages]),                true ],
      [ "Withholding Tax",                    fmt(totals[:withholding_tax]),             false ],
      [ "Social Security Tax (Employee)",     fmt(totals[:social_security_employee]),    false ],
      [ "Social Security Tax (Employer)",     fmt(totals[:social_security_employer]),    false ],
      [ "Medicare Tax (Employee)",            fmt(totals[:medicare_employee]),           false ],
      [ "Medicare Tax (Employer)",            fmt(totals[:medicare_employer]),           false ],
      [ "Total Employment Taxes",             fmt(totals[:total_employment_taxes]),      true ]
    ]

    table_data = rows.map { |label, value, highlight|
      bg = highlight ? HIGHLIGHT_BG : "FFFFFF"
      style = highlight ? :bold : :normal
      [
        { content: label, font_style: style, background_color: bg },
        { content: value, align: :right, font_style: style, background_color: bg }
      ]
    }

    pdf.table(table_data,
      width: pdf.bounds.width,
      cell_style: { size: 10, padding: [ 6, 10 ], border_color: BORDER_GRAY }
    ) do
      column(0).width = pdf.bounds.width * 0.65
      column(0).text_color = TEXT_DARK
      column(1).text_color = TEXT_DARK
    end

    pdf.fill_color TEXT_DARK
    pdf.move_down 18

    # Disclaimer note
    pdf.fill_color TEXT_MUTED
    pdf.font_size(8) do
      pdf.text(
        "This summary is based on committed payroll periods only. " \
        "Verify against your payroll tax accounts before filing. " \
        "Social Security employee + employer totals combined represent the full FICA obligation.",
        style: :italic
      )
    end
    pdf.fill_color TEXT_DARK
  end

  def render_payroll_fields_block(pdf)
    rows = Array(report.dig(:payroll_fields, :totals))
    return if rows.empty?

    pdf.start_new_page if pdf.cursor < 180
    pdf.font_size(11) { pdf.text "Payroll Field Reconciliation", style: :bold }
    pdf.move_down 3
    pdf.fill_color TEXT_MUTED
    pdf.font_size(8) { pdf.text "Historical amounts snapshotted on payroll items in this pay-date period." }
    pdf.fill_color TEXT_DARK
    pdf.move_down 6

    table_data = [ [ "Field", "Treatment", "Paid by", "Amount" ] ] + rows.map do |entry|
      [
        entry[:label].to_s,
        entry[:tax_treatment].to_s.humanize,
        entry[:employer_paid] ? "Employer" : "Employee",
        fmt(entry[:amount])
      ]
    end
    pdf.table(table_data, width: pdf.bounds.width, header: true,
      cell_style: { size: 8, padding: [ 4, 6 ], border_color: BORDER_GRAY }) do
      row(0).background_color = SECTION_BG
      row(0).font_style = :bold
      column(3).align = :right
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────────────────

  def fmt(value)
    format("$%.2f", value.to_f)
  end

  def period_label(period)
    return period[:label] if period[:label].present?
    return "Q#{period[:quarter]} #{period[:year]}" if period[:quarter]

    "#{period[:year]} Full Year"
  end
end
