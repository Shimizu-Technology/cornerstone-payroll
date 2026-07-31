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

  it "neutralizes formula-like text values before spreadsheet export" do
    formula_like_values = [
      "=1+1",
      "+SUM(A1:A2)",
      "-2+3",
      "@cmd",
      "\t=1+1",
      "\r=1+1"
    ]
    exporter = described_class.new(
      filename: "payroll-summary.csv",
      sheet: {
        name: "Employee Summary",
        rows: [ formula_like_values + [ "Plain text" ] ]
      }
    )

    expect(CSV.parse(exporter.generate).first).to eq(
      formula_like_values.map { |value| "'#{value.sub(/\A[\t\r]+/, "")}" } + [ "Plain text" ]
    )
  end
end
