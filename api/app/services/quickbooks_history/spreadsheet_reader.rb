# frozen_string_literal: true

require "roo"
require "spreadsheet"

module QuickbooksHistory
  class SpreadsheetReader
    class UnsupportedFormat < StandardError; end

    def self.read(path:, extension:)
      case extension.to_s.downcase
      when ".xls"
        workbook = Spreadsheet.open(path.to_s)
        worksheet = workbook.worksheet(0)
        worksheet.map { |row| Array(row).map { |cell| cell.respond_to?(:value) ? cell.value : cell } }
      when ".xlsx"
        workbook = Roo::Spreadsheet.open(path.to_s, extension: :xlsx)
        begin
          sheet = workbook.sheet(0)
          (sheet.first_row..sheet.last_row).map { |row_number| sheet.row(row_number) }
        ensure
          workbook.close
        end
      else
        raise UnsupportedFormat, "Only QuickBooks .xls and .xlsx spreadsheets can be parsed"
      end
    end
  end
end
