# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollRegisterCsvExporter do
  let(:report_data) do
    {
      type: "payroll_register",
      meta: { generated_at: "2025-03-20T10:00:00Z" },
      pay_period: {
        id: 42,
        start_date: "2025-03-01",
        end_date: "2025-03-14",
        pay_date: "2025-03-19",
        status: "committed"
      },
      summary: {
        employee_count: 2,
        total_gross: 5000.00,
        total_withholding: 350.00,
        total_social_security: 310.00,
        total_medicare: 72.50,
        total_retirement: 200.00,
        total_deductions: 932.50,
        total_net: 4067.50
      },
      employees: [
        {
          employee_id: 1,
          employee_name: "Alice Terlaje",
          employment_type: "hourly",
          pay_rate: 20.00,
          hours_worked: 80.0,
          overtime_hours: 5.0,
          gross_pay: 1950.00,
          withholding_tax: 140.00,
          social_security_tax: 120.90,
          medicare_tax: 28.28,
          retirement_payment: 78.00,
          total_deductions: 367.18,
          net_pay: 1582.82,
          check_number: "10001"
        },
        {
          employee_id: 2,
          employee_name: "Bob Meno",
          employment_type: "salary",
          pay_rate: 75_000.00,
          hours_worked: nil,
          overtime_hours: nil,
          gross_pay: 3050.00,
          withholding_tax: 210.00,
          social_security_tax: 189.10,
          medicare_tax: 44.22,
          retirement_payment: 122.00,
          total_deductions: 565.32,
          net_pay: 2484.68,
          check_number: "10002"
        }
      ]
    }
  end

  subject(:exporter) { described_class.new(report_data) }

  describe "#generate" do
    it "returns a String" do
      expect(exporter.generate).to be_a(String)
    end

    it "starts with the header row containing expected columns" do
      first_line = exporter.generate.lines.first.chomp
      expect(first_line).to include("Employee Name")
      expect(first_line).to include("Gross Pay")
      expect(first_line).to include("Net Pay")
      expect(first_line).to include("Check Number")
    end

    it "includes both employee rows" do
      csv = exporter.generate
      expect(csv).to include("Alice Terlaje")
      expect(csv).to include("Bob Meno")
    end

    it "formats currency values with two decimal places" do
      csv = exporter.generate
      expect(csv).to include("1950.00")
      expect(csv).to include("1582.82")
    end

    it "includes a TOTALS summary row" do
      csv = exporter.generate
      expect(csv).to include("TOTALS")
      expect(csv).to include("5000.00")
    end

    it "includes employee count in TOTALS row" do
      csv = exporter.generate
      expect(csv).to include("2 employees")
    end

    it "handles nil hours gracefully (salary employee)" do
      csv = exporter.generate
      expect { exporter.generate }.not_to raise_error
      # nil becomes 0.0
      expect(csv).to include("0.0")
    end

    it "sanitizes CSV formula injection in employee names" do
      report_data[:employees].first[:employee_name] = "=HYPERLINK(\"http://evil\")"
      csv = exporter.generate
      expect(csv).to include("'=HYPERLINK")
    end

    it "sanitizes CSV formula injection in check numbers" do
      report_data[:employees].first[:check_number] = "+12345"
      csv = exporter.generate
      expect(csv).to include("'+12345")
    end

    it "handles nil employees array without raising" do
      report_data[:employees] = nil
      expect { exporter.generate }.not_to raise_error
    end

    it "handles nil summary without raising" do
      report_data[:summary] = nil
      expect { exporter.generate }.not_to raise_error
    end
  end

  describe "#filename" do
    it "includes pay period date range" do
      expect(exporter.filename).to eq("payroll_register_2025-03-01_to_2025-03-14.csv")
    end

    it "falls back to unknown_period when dates are missing" do
      report_data[:pay_period] = {}
      expect(exporter.filename).to eq("payroll_register_unknown_period.csv")
    end
  end
end
