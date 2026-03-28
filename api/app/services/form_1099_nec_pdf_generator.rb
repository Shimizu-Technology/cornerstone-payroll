# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Form1099NecPdfGenerator
#
# Generates a Prawn PDF filing-prep summary from Form1099NecAggregator output.
# Layout: payer info → year → contractor table → totals → compliance
#
# Usage:
#   report_data = Form1099NecAggregator.new(company, year).generate
#   pdf_bytes   = Form1099NecPdfGenerator.new(report_data).generate
#
class Form1099NecPdfGenerator
  include PdfFooter

  HEADER_BG   = "065F46"   # emerald
  SECTION_BG  = "ECFDF5"   # light emerald
  ALERT_BG    = "FFF3CD"   # amber
  DANGER_BG   = "FDECEA"   # red
  BORDER_GRAY = "CCCCCC"
  TEXT_DARK   = "1A1A2E"
  TEXT_MUTED  = "666666"

  attr_reader :report

  def initialize(report_data)
    @report = report_data
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", margin: [ 36, 40, 50, 40 ])
    pdf.font_families.update("Helvetica" => { normal: "Helvetica", bold: "Helvetica-Bold", italic: "Helvetica-Oblique" })
    pdf.font "Helvetica"

    render_header(pdf)
    render_payer_info(pdf)
    render_summary_totals(pdf)
    render_contractor_table(pdf)
    render_compliance(pdf)
    render_caveats(pdf)

    render_with_footer(pdf, "1099-NEC Preparation Summary – #{report[:meta][:year]}")
  end

  private

  def render_header(pdf)
    pdf.fill_color HEADER_BG
    pdf.fill_rectangle [ pdf.bounds.left, pdf.cursor ], pdf.bounds.width, 50
    pdf.fill_color "FFFFFF"
    pdf.text_box "1099-NEC Preparation Summary", at: [ 12, pdf.cursor - 8 ], size: 18, style: :bold
    pdf.text_box "Tax Year #{report[:meta][:year]}", at: [ 12, pdf.cursor - 30 ], size: 10
    pdf.fill_color TEXT_DARK
    pdf.move_down 60
  end

  def render_payer_info(pdf)
    payer = report[:payer]
    pdf.text "Payer Information", size: 12, style: :bold
    pdf.move_down 4
    pdf.text "#{payer[:name]}", size: 10
    pdf.text "EIN: #{payer[:ein] || 'Not on file'}", size: 9, color: TEXT_MUTED
    pdf.text "#{payer[:address]}", size: 9, color: TEXT_MUTED if payer[:address].present?
    pdf.text "#{payer[:city_state_zip]}", size: 9, color: TEXT_MUTED if payer[:city_state_zip].present?
    pdf.move_down 12
  end

  def render_summary_totals(pdf)
    totals = report[:totals]
    meta = report[:meta]

    data = [
      [ "Total Contractors", meta[:contractor_count].to_s ],
      [ "Reportable (>= $#{Form1099NecAggregator::FILING_THRESHOLD})", meta[:reportable_count].to_s ],
      [ "Total Compensation", fmt(totals[:total_compensation]) ],
      [ "Reportable Compensation", fmt(totals[:reportable_compensation]) ],
      [ "Federal Tax Withheld", fmt(totals[:total_federal_withheld]) ]
    ]

    pdf.table(
      [ [ { content: "Summary", colspan: 2, background_color: HEADER_BG, text_color: "FFFFFF", font_style: :bold } ] ] + data,
      column_widths: [ 260, pdf.bounds.width - 260 ],
      cell_style: { size: 9, padding: [ 4, 8 ], border_color: BORDER_GRAY }
    ) do |t|
      data.each_with_index do |_, i|
        t.row(i + 1).column(0).font_style = :bold
        t.row(i + 1).background_color = i.even? ? SECTION_BG : "FFFFFF"
      end
    end
    pdf.move_down 16
  end

  def render_contractor_table(pdf)
    contractors = report[:reportable_contractors] || []
    return if contractors.empty?

    pdf.text "Reportable Contractors", size: 12, style: :bold
    pdf.move_down 4

    header = [ "Name / Business", "TIN (last 4)", "Type", "Payments", "Box 1 (Compensation)", "Box 4 (Withheld)", "W-9" ]
    rows = contractors.map do |c|
      name_display = c[:business_name].present? ? "#{c[:name]}\n#{c[:business_name]}" : c[:name]
      [
        name_display,
        "***#{c[:tin_last_four] || '????'}",
        c[:tin_type],
        c[:payment_count].to_s,
        fmt(c[:total_compensation]),
        fmt(c[:federal_withheld]),
        c[:w9_on_file] ? "Yes" : "NO"
      ]
    end

    pdf.table(
      [ header ] + rows,
      header: true,
      column_widths: [ 140, 65, 40, 50, 90, 80, 35 ],
      cell_style: { size: 8, padding: [ 3, 4 ], border_color: BORDER_GRAY }
    ) do |t|
      t.row(0).background_color = HEADER_BG
      t.row(0).text_color = "FFFFFF"
      t.row(0).font_style = :bold
      rows.each_index do |i|
        t.row(i + 1).background_color = i.even? ? "FFFFFF" : SECTION_BG
        unless contractors[i][:w9_on_file]
          t.row(i + 1).column(6).background_color = DANGER_BG
          t.row(i + 1).column(6).text_color = "CC0000"
          t.row(i + 1).column(6).font_style = :bold
        end
      end
    end
    pdf.move_down 16
  end

  def render_compliance(pdf)
    issues = (report[:reportable_contractors] || []).select { |c| c[:compliance_issues]&.any? }
    return if issues.empty?

    pdf.text "Compliance Issues", size: 12, style: :bold, color: "CC0000"
    pdf.move_down 4

    issues.each do |c|
      pdf.fill_color DANGER_BG
      pdf.fill_rectangle [ 0, pdf.cursor ], pdf.bounds.width, 20
      pdf.fill_color TEXT_DARK
      pdf.text_box "#{c[:name]}: #{c[:compliance_issues].join(', ')}", at: [ 6, pdf.cursor - 4 ], size: 8
      pdf.move_down 22
    end
    pdf.move_down 8
  end

  def render_caveats(pdf)
    caveats = report.dig(:meta, :caveats)
    return if caveats.blank?

    pdf.fill_color ALERT_BG
    box_height = 12 + (caveats.length * 14)
    pdf.fill_rectangle [ 0, pdf.cursor ], pdf.bounds.width, box_height
    pdf.fill_color TEXT_DARK
    y = pdf.cursor - 6
    pdf.text_box "Notes:", at: [ 6, y ], size: 8, style: :bold
    y -= 12
    caveats.each do |caveat|
      pdf.text_box "• #{caveat}", at: [ 10, y ], width: pdf.bounds.width - 20, size: 7, color: TEXT_MUTED
      y -= 14
    end
    pdf.move_down box_height + 8
  end

  def fmt(amount)
    "$#{'%.2f' % (amount || 0)}"
  end
end
