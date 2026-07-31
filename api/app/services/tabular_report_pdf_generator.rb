# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Renders normalized spreadsheet-style report sheets into a readable PDF.
# It deliberately consumes the same rows as SpreadsheetReportExporter so a
# report's human and analytical exports share one data contract.
class TabularReportPdfGenerator
  include PdfFooter

  HEADER_BG = "1E3A5F"
  SUBHEADER_BG = "EAF1F8"
  TEXT_DARK = "172033"
  TEXT_MUTED = "607089"
  BORDER = "CBD5E1"

  def initialize(title:, subtitle:, filename:, sheets:, landscape: true)
    @title = title
    @subtitle = subtitle
    @filename = filename
    @sheets = Array(sheets).map { |sheet| sheet.to_h.deep_symbolize_keys }
    @landscape = landscape
  end

  attr_reader :filename

  def generate
    pdf = Prawn::Document.new(
      page_size: "LETTER",
      page_layout: @landscape ? :landscape : :portrait,
      margin: [ 34, 28, 48, 28 ]
    )

    render_header(pdf)
    @sheets.each_with_index do |sheet, index|
      pdf.start_new_page unless index.zero?
      render_sheet(pdf, sheet)
    end

    render_with_footer(pdf, [ @title, @subtitle, "CONFIDENTIAL" ].compact_blank.join(" — "), font_size: 7)
  end

  private

  def render_header(pdf)
    pdf.fill_color HEADER_BG
    pdf.fill_rectangle [ pdf.bounds.left, pdf.bounds.top ], pdf.bounds.width, 54
    pdf.fill_color "FFFFFF"
    pdf.bounding_box([ pdf.bounds.left + 12, pdf.bounds.top - 11 ], width: pdf.bounds.width - 24) do
      pdf.font_size(17) { pdf.text @title, style: :bold }
      pdf.font_size(9) { pdf.text @subtitle.to_s } if @subtitle.present?
    end
    pdf.fill_color TEXT_DARK
    pdf.move_down 66
  end

  def render_sheet(pdf, sheet)
    rows = Array(sheet[:rows]).map { |row| Array(row).map { |value| display_value(value) } }
    return if rows.empty?

    pdf.font_size(13) { pdf.text sheet[:name].to_s, style: :bold, color: TEXT_DARK }
    pdf.move_down 8

    font_size = rows.first.length > 12 ? 6 : (rows.first.length > 8 ? 7 : 8)
    pdf.table(rows, width: pdf.bounds.width, header: true, cell_style: {
      size: font_size,
      padding: [ 4, 4 ],
      border_color: BORDER,
      overflow: :shrink_to_fit,
      min_font_size: 5
    }) do
      row(0).background_color = SUBHEADER_BG
      row(0).font_style = :bold
      row(0).text_color = TEXT_DARK
      cells.text_color = TEXT_DARK
    end
  end

  def display_value(value)
    case value
    when BigDecimal
      format("%.2f", value)
    when Float
      value.round(2)
    when Date, Time, DateTime, ActiveSupport::TimeWithZone
      value.to_s
    when true
      "Yes"
    when false
      "No"
    else
      value.to_s
    end
  end
end
