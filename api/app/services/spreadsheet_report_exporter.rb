# frozen_string_literal: true

require "caxlsx"

class SpreadsheetReportExporter
  CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

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
        Array(sheet[:rows]).each do |row|
          worksheet.add_row(Array(row).map { |value| cell_value(value) })
        end
        worksheet.column_widths(*Array(sheet[:column_widths])) if sheet[:column_widths].present?
      end
    end

    package.to_stream.read
  end

  private

  def safe_sheet_name(name)
    name.to_s.gsub(%r{[\[\]\*?/\\:]}, " ").squish.truncate(31, omission: "")
  end

  def cell_value(value)
    case value
    when BigDecimal
      value.to_f
    when Date, Time, DateTime
      value.to_s
    else
      value
    end
  end
end
