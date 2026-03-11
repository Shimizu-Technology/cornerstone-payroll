# frozen_string_literal: true

require "prawn"
require "prawn/table"

# W2GuPdfGenerator
#
# Generates a Prawn PDF filing-prep summary from W2GuAggregator output.
# Layout: employer metadata → year → totals → compliance block → employee table.
#
# Usage:
#   report_data = W2GuAggregator.new(company, year).generate
#   pdf_bytes   = W2GuPdfGenerator.new(report_data).generate
#
class W2GuPdfGenerator
  # Colors
  HEADER_BG    = "2B4090"   # deep blue
  SECTION_BG   = "F0F4FF"   # light blue tint
  ALERT_BG     = "FFF3CD"   # amber for caveats
  DANGER_BG    = "FDECEA"   # red for compliance issues
  BORDER_GRAY  = "CCCCCC"
  TEXT_DARK    = "1A1A2E"
  TEXT_MUTED   = "666666"

  attr_reader :report

  def initialize(report_data)
    @report = report_data
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", margin: [ 36, 36, 36, 36 ])
    render_document(pdf)
    pdf.render
  end

  def filename
    company_slug = report.dig(:employer, :name)&.gsub(/[^0-9A-Za-z]/, "_")&.downcase || "company"
    "w2gu_#{company_slug}_#{report.dig(:meta, :year)}.pdf"
  end

  private

  def render_document(pdf)
    render_header(pdf)
    render_employer_block(pdf)
    render_totals_block(pdf)
    render_compliance_block(pdf)
    render_caveats_block(pdf)
    render_employee_table(pdf)
    render_footer(pdf)
  end

  # ─── Header ────────────────────────────────────────────────────────────────

  def render_header(pdf)
    pdf.fill_color HEADER_BG
    pdf.fill_rectangle [ pdf.bounds.left, pdf.bounds.top ], pdf.bounds.width, 52
    pdf.fill_color "FFFFFF"

    pdf.bounding_box([ pdf.bounds.left + 12, pdf.bounds.top - 10 ], width: pdf.bounds.width - 24) do
      pdf.font_size(18) { pdf.text "W-2GU Annual Filing Preparation Report", style: :bold }
      pdf.font_size(10) { pdf.text "Guam Territorial W-2 — For Review Before Filing with DRT" }
    end

    pdf.fill_color TEXT_DARK
    pdf.move_down 60
  end

  # ─── Employer Block ─────────────────────────────────────────────────────────

  def render_employer_block(pdf)
    employer  = report[:employer]
    meta      = report[:meta]

    pdf.font_size(11) { pdf.text "Employer Information", style: :bold }
    pdf.move_down 4

    rows = [
      [ "Company", employer[:name].to_s ],
      [ "EIN", employer[:ein].presence || "NOT PROVIDED" ],
      [ "Address", employer[:address].presence || "NOT PROVIDED" ],
      [ "Tax Year", meta[:year].to_s ],
      [ "Employees Included", meta[:employee_count].to_s ],
      [ "Generated At", meta[:generated_at].to_s ]
    ]

    pdf.fill_color SECTION_BG
    table_data = rows.map { |k, v| [ { content: k, font_style: :bold }, v ] }

    pdf.table(table_data,
      width: pdf.bounds.width,
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

  # ─── Totals Block ───────────────────────────────────────────────────────────

  def render_totals_block(pdf)
    totals = report[:totals]

    pdf.font_size(11) { pdf.text "Annual Totals (All Employees)", style: :bold }
    pdf.move_down 4

    rows = [
      [ "Box 1 — Wages, Tips & Other Comp",     fmt(totals[:box1_wages_tips_other_comp]) ],
      [ "Box 2 — Federal Income Tax Withheld",  fmt(totals[:box2_federal_income_tax_withheld]) ],
      [ "Box 3 — Social Security Wages",         fmt(totals[:box3_social_security_wages]) ],
      [ "Box 4 — SS Tax Withheld",               fmt(totals[:box4_social_security_tax_withheld]) ],
      [ "Box 5 — Medicare Wages & Tips",         fmt(totals[:box5_medicare_wages_tips]) ],
      [ "Box 6 — Medicare Tax Withheld",         fmt(totals[:box6_medicare_tax_withheld]) ],
      [ "Box 7 — Social Security Tips",          fmt(totals[:box7_social_security_tips]) ],
      [ "Reported Tips (Uncapped)",              fmt(totals[:reported_tips_total]) ]
    ]

    table_data = rows.map { |label, val|
      [ { content: label, font_style: :bold }, { content: val, align: :right } ]
    }

    pdf.table(table_data,
      width: pdf.bounds.width,
      cell_style: { size: 9, padding: [ 4, 8 ], border_color: BORDER_GRAY }
    ) do
      column(0).width = 300
      column(0).background_color = SECTION_BG
      column(0).text_color = TEXT_DARK
      column(1).text_color = TEXT_DARK
      row(0).borders = [ :top, :left, :right, :bottom ]
    end

    pdf.fill_color TEXT_DARK
    pdf.move_down 14
  end

  # ─── Compliance Issues ──────────────────────────────────────────────────────

  def render_compliance_block(pdf)
    issues = report[:compliance_issues]

    pdf.font_size(11) { pdf.text "Compliance Issues", style: :bold }
    pdf.move_down 4

    if issues.empty?
      pdf.fill_color "2D6A4F"
      pdf.font_size(9) { pdf.text "[OK]  No compliance issues detected.", style: :italic }
      pdf.fill_color TEXT_DARK
    else
      issues.each do |issue|
        pdf.table(
          [[ "[!]  #{issue}" ]],
          width: pdf.bounds.width,
          cell_style: {
            background_color: DANGER_BG,
            text_color: "C0392B",
            size: 9,
            padding: [ 4, 8 ],
            border_width: 0,
            inline_format: false
          }
        )
        pdf.move_down 4
      end
      pdf.fill_color TEXT_DARK
    end

    pdf.move_down 10
  end

  # ─── Caveats Block ──────────────────────────────────────────────────────────

  def render_caveats_block(pdf)
    caveats = report.dig(:meta, :caveats) || []
    return if caveats.empty?

    pdf.font_size(11) { pdf.text "Notes & Caveats", style: :bold }
    pdf.move_down 4

    pdf.fill_color ALERT_BG
    pdf.fill_rectangle [ pdf.bounds.left, pdf.cursor ], pdf.bounds.width, (caveats.length * 16) + 10
    pdf.fill_color "7D6608"

    pdf.bounding_box([ pdf.bounds.left + 8, pdf.cursor - 5 ], width: pdf.bounds.width - 16) do
      caveats.each do |caveat|
        pdf.font_size(8) { pdf.text "- #{caveat}" }
        pdf.move_down 4
      end
    end

    pdf.fill_color TEXT_DARK
    pdf.move_down (caveats.length * 16) + 16
  end

  # ─── Employee Table ─────────────────────────────────────────────────────────

  def render_employee_table(pdf)
    employees = report[:employees]

    pdf.start_new_page if pdf.cursor < 120
    pdf.font_size(11) { pdf.text "Employee Detail", style: :bold }
    pdf.move_down 6

    if employees.empty?
      pdf.font_size(9) { pdf.text "No committed payroll data found for #{report.dig(:meta, :year)}.", style: :italic, color: TEXT_MUTED }
      return
    end

    header = [
      { content: "Employee",   background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold },
      { content: "SSN",        background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold },
      { content: "Box 1\nWages", background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Box 2\nFed W/H", background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Box 3\nSS Wages", background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Box 4\nSS W/H", background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Box 5\nMed Wages", background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Box 6\nMed W/H", background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right },
      { content: "Box 7\nSS Tips", background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold, align: :right }
    ]

    rows = employees.map { |emp| employee_table_row(emp) }

    # Totals footer
    t = report[:totals]
    totals_row = [
      { content: "TOTALS", font_style: :bold, background_color: SECTION_BG },
      { content: "", background_color: SECTION_BG },
      { content: fmt(t[:box1_wages_tips_other_comp]), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t[:box2_federal_income_tax_withheld]), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t[:box3_social_security_wages]), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t[:box4_social_security_tax_withheld]), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t[:box5_medicare_wages_tips]), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t[:box6_medicare_tax_withheld]), align: :right, font_style: :bold, background_color: SECTION_BG },
      { content: fmt(t[:box7_social_security_tips]), align: :right, font_style: :bold, background_color: SECTION_BG }
    ]

    table_data = [ header ] + rows + [ totals_row ]

    page_width = pdf.bounds.width
    col_widths = [
      page_width * 0.17,  # Employee
      page_width * 0.09,  # SSN
      page_width * 0.09,  # Box 1
      page_width * 0.09,  # Box 2
      page_width * 0.09,  # Box 3
      page_width * 0.09,  # Box 4
      page_width * 0.10,  # Box 5
      page_width * 0.09,  # Box 6
      page_width * 0.09   # Box 7
    ]
    # Adjust last column to fill remaining width
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
      row(0).height = 26
    end

    pdf.fill_color TEXT_DARK
  end

  def employee_table_row(emp)
    ssn_label = emp[:employee_ssn_last4].present? ? "***-**-#{emp[:employee_ssn_last4]}" : "MISSING"
    tip_cap    = emp[:box7_limited_by_wage_base] ? " (capped)" : ""
    missing_ssn_bg = emp[:has_missing_ssn] ? "FFF8E7" : "FFFFFF"

    [
      { content: emp[:employee_name].to_s, background_color: missing_ssn_bg },
      { content: ssn_label, background_color: missing_ssn_bg, font_style: (emp[:has_missing_ssn] ? :bold : :normal), text_color: (emp[:has_missing_ssn] ? "C0392B" : TEXT_DARK) },
      { content: fmt(emp[:box1_wages_tips_other_comp]), align: :right },
      { content: fmt(emp[:box2_federal_income_tax_withheld]), align: :right },
      { content: fmt(emp[:box3_social_security_wages]), align: :right },
      { content: fmt(emp[:box4_social_security_tax_withheld]), align: :right },
      { content: fmt(emp[:box5_medicare_wages_tips]), align: :right },
      { content: fmt(emp[:box6_medicare_tax_withheld]), align: :right },
      { content: "#{fmt(emp[:box7_social_security_tips])}#{tip_cap}", align: :right }
    ]
  end

  # ─── Footer ─────────────────────────────────────────────────────────────────

  def render_footer(pdf)
    pdf.repeat(:all) do
      pdf.bounding_box([ pdf.bounds.left, pdf.bounds.bottom + 18 ], width: pdf.bounds.width) do
        pdf.stroke_horizontal_rule
        pdf.move_down 4
        pdf.fill_color TEXT_MUTED
        pdf.font_size(7) do
          pdf.text(
            "W-2GU Filing Preparation Summary — #{report.dig(:employer, :name)} — #{report.dig(:meta, :year)} — " \
            "Generated #{report.dig(:meta, :generated_at)} — CONFIDENTIAL, FOR INTERNAL USE ONLY",
            align: :center
          )
        end
        pdf.fill_color TEXT_DARK
      end
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────────────────

  def fmt(value)
    format("$%.2f", value.to_f)
  end
end
