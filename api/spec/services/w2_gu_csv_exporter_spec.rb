# frozen_string_literal: true

require "rails_helper"

RSpec.describe W2GuCsvExporter do
  let(:report_data) do
    {
      meta: {
        report_type: "w2_gu",
        company_id: 1,
        company_name: "Shimizu Industries",
        year: 2025,
        generated_at: "2025-02-01T10:00:00Z",
        employee_count: 2,
        caveats: [ "This report is a preparation summary." ]
      },
      employer: {
        name: "Shimizu Industries",
        ein: "12-3456789",
        address: "123 Marine Drive, Tamuning, GU 96913"
      },
      totals: {
        box1_wages_tips_other_comp: 8100.0,
        box2_federal_income_tax_withheld: 600.0,
        box3_social_security_wages: 8000.0,
        box4_social_security_tax_withheld: 496.0,
        box5_medicare_wages_tips: 8100.0,
        box6_medicare_tax_withheld: 117.45,
        box7_social_security_tips: 100.0,
        reported_tips_total: 100.0
      },
      compliance_issues: [],
      employees: [
        {
          employee_id: 1,
          employee_name: "Alice Terlaje",
          employee_ssn_last4: "6789",
          employee_address: "1 Main St, Hagåtña, GU 96910",
          box1_wages_tips_other_comp: 5100.0,
          box2_federal_income_tax_withheld: 350.0,
          box3_social_security_wages: 5000.0,
          box4_social_security_tax_withheld: 310.0,
          box5_medicare_wages_tips: 5100.0,
          box6_medicare_tax_withheld: 73.95,
          box7_social_security_tips: 100.0,
          reported_tips_total: 100.0,
          box7_limited_by_wage_base: false,
          has_missing_ssn: false,
          has_missing_address: false
        },
        {
          employee_id: 2,
          employee_name: "Bob Meno",
          employee_ssn_last4: nil,
          employee_address: "",
          box1_wages_tips_other_comp: 3000.0,
          box2_federal_income_tax_withheld: 250.0,
          box3_social_security_wages: 3000.0,
          box4_social_security_tax_withheld: 186.0,
          box5_medicare_wages_tips: 3000.0,
          box6_medicare_tax_withheld: 43.5,
          box7_social_security_tips: 0.0,
          reported_tips_total: 0.0,
          box7_limited_by_wage_base: false,
          has_missing_ssn: true,
          has_missing_address: true
        }
      ]
    }
  end

  subject(:exporter) { described_class.new(report_data) }

  describe "#generate" do
    it "returns a String" do
      expect(exporter.generate).to be_a(String)
    end

    it "starts with the header row" do
      csv = exporter.generate
      first_line = csv.lines.first.chomp
      expect(first_line).to include("Employee Name")
      expect(first_line).to include("SSN (Last 4)")
      expect(first_line).to include("Box 1")
      expect(first_line).to include("Box 7")
    end

    it "includes both employee rows" do
      csv = exporter.generate
      expect(csv).to include("Alice Terlaje")
      expect(csv).to include("Bob Meno")
    end

    it "masks SSN correctly for employees with SSN" do
      csv = exporter.generate
      expect(csv).to include("***-**-6789")
    end

    it "shows MISSING for employees without SSN" do
      csv = exporter.generate
      expect(csv).to include("MISSING")
    end

    it "includes a TOTALS row at the end" do
      csv = exporter.generate
      expect(csv).to include("TOTALS")
    end

    it "shows 'Yes' for capped box 7" do
      report_data[:employees].first[:box7_limited_by_wage_base] = true
      csv = exporter.generate
      expect(csv).to include("Yes")
    end

    it "includes correct total for box1" do
      csv = exporter.generate
      expect(csv).to include("8100.00")
    end

    it "formats currency with two decimal places" do
      csv = exporter.generate
      # Alice's box6 = 73.95
      expect(csv).to include("73.95")
    end
  end

  describe "#filename" do
    it "includes company slug and year" do
      expect(exporter.filename).to eq("w2gu_shimizu_industries_2025.csv")
    end
  end
end
