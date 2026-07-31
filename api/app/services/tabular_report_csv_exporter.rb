# frozen_string_literal: true

require "csv"

# Produces a flat CSV from the same normalized sheet rows used by XLSX and PDF
# report exports. Callers choose the sheet whose grain is appropriate for CSV.
class TabularReportCsvExporter
  FORMULA_PREFIXES = [ "=", "+", "-", "@", "\t", "\r" ].freeze

  attr_reader :filename

  def initialize(filename:, sheet:)
    @filename = filename
    @sheet = sheet.to_h.deep_symbolize_keys
  end

  def generate
    CSV.generate(headers: false) do |csv|
      Array(@sheet[:rows]).each do |row|
        csv << Array(row).map { |value| normalize_value(value) }
      end
    end
  end

  private

  # Report builders intentionally share their normalized rows across XLSX, PDF,
  # and CSV. Keep aggregate Floats readable and neutralize formula-like text so
  # spreadsheet applications do not execute user-controlled report values.
  def normalize_value(value)
    return value.round(10) if value.is_a?(Float) && value.finite?
    return value unless value.is_a?(String)

    return value unless value.start_with?(*FORMULA_PREFIXES)

    "'#{value.sub(/\A[\t\r]+/, "")}"
  end
end
