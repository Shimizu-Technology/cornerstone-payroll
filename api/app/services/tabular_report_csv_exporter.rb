# frozen_string_literal: true

require "csv"

# Produces a flat CSV from the same normalized sheet rows used by XLSX and PDF
# report exports. Callers choose the sheet whose grain is appropriate for CSV.
class TabularReportCsvExporter
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
  # and CSV. Aggregate arithmetic can leave Float values with binary transport
  # noise such as 1973.3999999999999. Preserve useful precision while keeping
  # the downloaded flat file clean.
  def normalize_value(value)
    return value unless value.is_a?(Float) && value.finite?

    value.round(10)
  end
end
