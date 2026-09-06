# frozen_string_literal: true

require "caxlsx"

class SpreadsheetReportExporter
  CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  FORMULA_PREFIXES = [ "=", "+", "-", "@", "\t", "\r" ].freeze

  attr_reader :filename

  def initialize(filename:, sheets:)
    @filename = filename
    @sheets = sheets
  end

  def generate
    package = Axlsx::Package.new
    workbook = package.workbook

    @sheets.each do |sheet|
      workbook.add_worksheet(name: safe_sheet_name(sheet.fetch(:name))) do |worksheet|
        style_ids = build_style_ids(workbook, sheet)
        row_heights = sheet.fetch(:row_heights, {})

        Array(sheet[:rows]).each_with_index do |row, row_index|
          options = {}
          row_style = style_for_row(sheet, style_ids, row_index)
          options[:style] = row_style if row_style
          options[:height] = row_heights[row_index] if row_heights.key?(row_index)

          worksheet.add_row(Array(row).map { |value| cell_value(value) }, **options)
        end
        worksheet.column_widths(*Array(sheet[:column_widths])) if sheet[:column_widths].present?
        Array(sheet[:merged_cells]).each { |range| worksheet.merge_cells(range) }
        configure_sheet_view(worksheet, sheet)
      end
    end

    package.to_stream.read
  end

  private

  def build_style_ids(workbook, sheet)
    sheet.fetch(:styles, {}).each_with_object({}) do |(name, options), ids|
      ids[name.to_sym] = workbook.styles.add_style(options)
    end
  end

  def style_for_row(sheet, style_ids, row_index)
    rule = Array(sheet[:row_style_rules]).find do |candidate|
      row_selector_matches?(candidate.fetch(:rows), row_index)
    end
    return nil unless rule

    if rule[:styles]
      Array(rule[:styles]).map { |name| name ? style_ids.fetch(name.to_sym) : 0 }
    elsif rule[:style]
      style_ids.fetch(rule[:style].to_sym)
    end
  end

  def row_selector_matches?(selector, row_index)
    selector.respond_to?(:cover?) ? selector.cover?(row_index) : Array(selector).include?(row_index)
  end

  def configure_sheet_view(worksheet, sheet)
    view = worksheet.sheet_view
    view.show_grid_lines = sheet[:show_grid_lines] unless sheet[:show_grid_lines].nil?
    view.zoom_scale = sheet[:zoom_scale] if sheet[:zoom_scale]
  end

  def safe_sheet_name(name)
    name.to_s.gsub(%r{[\[\]\*?/\\:]}, " ").squish.truncate(31, omission: "")
  end

  def cell_value(value)
    case value
    when BigDecimal
      value.to_f
    when Date, Time, DateTime
      value.to_s
    when String
      neutralize_formula(value)
    else
      value
    end
  end

  def neutralize_formula(value)
    return value unless value.start_with?(*FORMULA_PREFIXES)

    "'#{value.sub(/\A[\t\r]+/, "")}"
  end
end
