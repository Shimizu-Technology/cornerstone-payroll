# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe TabularReportCsvExporter do
  it "exports normalized rows without floating-point transport noise" do
    exporter = described_class.new(
      filename: "payroll-summary.csv",
      sheet: {
        name: "Employee Summary",
        rows: [
          [ "Employee", "Gross Pay", "Active" ],
          [ "Ana Perez", BigDecimal("1250.50"), true ],
          [ "Ben Cruz", 900.0, false ],
          [ "Grace Lee", 1973.3999999999999, true ]
        ]
      }
    )

    rows = CSV.parse(exporter.generate)

    expect(exporter.filename).to eq("payroll-summary.csv")
    expect(rows).to eq([
      [ "Employee", "Gross Pay", "Active" ],
      [ "Ana Perez", "1250.5", "true" ],
      [ "Ben Cruz", "900.0", "false" ],
      [ "Grace Lee", "1973.4", "true" ]
    ])
  end
end
