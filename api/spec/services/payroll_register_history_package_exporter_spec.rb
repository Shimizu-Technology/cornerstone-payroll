# frozen_string_literal: true

require "rails_helper"
require "zip"

RSpec.describe PayrollRegisterHistoryPackageExporter do
  it "packages every run with machine-readable manifests and separate W-2/1099 totals" do
    company = build_stubbed(:company, name: "AIRE Services")
    report = {
      source: { label: "Cornerstone" },
      pay_period: {
        key: "native:42", id: 42, record_type: "native", status: "committed",
        start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 15), pay_date: Date.new(2026, 4, 30)
      },
      summary: {
        employee_count: 2, contractor_count: 1,
        total_gross: 1_000, contractor_total_gross: 600,
        total_net: 800, contractor_total_net: 600
      }
    }
    exporter = described_class.new(
      company: company,
      format: "xlsx",
      entries: [ { report: report, path: "reports/001_native-42_register.xlsx", content: "workbook" } ]
    )

    Zip::File.open_buffer(StringIO.new(exporter.generate)) do |archive|
      expect(archive.entries.map(&:name)).to contain_exactly(
        "README.txt", "manifest.csv", "manifest.json", "reports/001_native-42_register.xlsx"
      )
      expect(archive.read("reports/001_native-42_register.xlsx")).to eq("workbook")
      manifest = JSON.parse(archive.read("manifest.json"))
      expect(manifest).to include("company" => "AIRE Services", "payroll_run_count" => 1, "report_format" => "xlsx")
      expect(manifest.dig("payroll_runs", 0)).to include(
        "pay_run_key" => "native:42",
        "w2_employee_count" => 2,
        "contractor_count" => 1,
        "combined_gross" => 1_600.0,
        "combined_net" => 1_400.0
      )
    end
  end

  it "rejects unsupported formats and empty histories" do
    company = build_stubbed(:company, name: "AIRE Services")

    expect { described_class.new(company: company, format: "csv", entries: [ {} ]) }
      .to raise_error(ArgumentError, /xlsx or pdf/)
    expect { described_class.new(company: company, format: "xlsx", entries: []) }
      .to raise_error(ArgumentError, /No reportable payroll runs/)
  end
end
