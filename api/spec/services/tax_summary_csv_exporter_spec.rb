# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxSummaryCsvExporter do
  let(:report_data) do
    {
      type: "tax_summary",
      meta: { generated_at: "2025-04-01T10:00:00Z" },
      period: {
        year: 2025,
        quarter: 1,
        start_date: "2025-01-01",
        end_date: "2025-03-31"
      },
      totals: {
        gross_wages: 9000.00,
        withholding_tax: 600.00,
        social_security_employee: 558.00,
        social_security_employer: 558.00,
        medicare_employee: 130.50,
        medicare_employer: 130.50,
        total_employment_taxes: 1977.00
      },
      pay_periods_included: 3,
      employee_count: 4
    }
  end

  subject(:exporter) { described_class.new(report_data) }

  describe "#generate" do
    it "returns a String" do
      expect(exporter.generate).to be_a(String)
    end

    it "includes the report title" do
      expect(exporter.generate).to include("Tax Summary Report")
    end

    it "includes year and quarter" do
      csv = exporter.generate
      expect(csv).to include("2025")
      expect(csv).to include("Q1")
    end

    it "includes period metadata" do
      csv = exporter.generate
      expect(csv).to include("Pay Periods Included")
      expect(csv).to include("3")
      expect(csv).to include("Employee Count")
      expect(csv).to include("4")
    end

    it "includes Gross Wages total with correct amount" do
      csv = exporter.generate
      expect(csv).to include("Gross Wages")
      expect(csv).to include("9000.00")
    end

    it "includes all tax category rows" do
      csv = exporter.generate
      expect(csv).to include("Withholding Tax")
      expect(csv).to include("Social Security (Employee)")
      expect(csv).to include("Social Security (Employer)")
      expect(csv).to include("Medicare (Employee)")
      expect(csv).to include("Medicare (Employer)")
      expect(csv).to include("Total Employment Taxes")
    end

    it "includes total employment taxes" do
      csv = exporter.generate
      expect(csv).to include("1977.00")
    end

    it "shows 'Full Year' when quarter is nil" do
      report_data[:period][:quarter] = nil
      csv = exporter.generate
      expect(csv).to include("Full Year")
    end

    it "handles nil totals without raising" do
      report_data[:totals] = nil
      expect { exporter.generate }.not_to raise_error
    end

    it "handles nil period without raising" do
      report_data[:period] = nil
      expect { exporter.generate }.not_to raise_error
    end
  end

  describe "#filename" do
    it "includes year and quarter when quarter is present" do
      expect(exporter.filename).to eq("tax_summary_2025_q1.csv")
    end

    it "omits quarter suffix when quarter is nil" do
      report_data[:period][:quarter] = nil
      expect(exporter.filename).to eq("tax_summary_2025.csv")
    end

    it "uses unknown when year is missing" do
      report_data[:period] = {}
      expect(exporter.filename).to eq("tax_summary_unknown.csv")
    end
  end
end
