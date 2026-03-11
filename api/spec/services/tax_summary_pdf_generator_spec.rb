# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxSummaryPdfGenerator do
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

  subject(:generator) { described_class.new(report_data) }

  describe "#generate" do
    it "returns a binary String" do
      result = generator.generate
      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "starts with PDF magic bytes (%PDF)" do
      result = generator.generate
      expect(result.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ])
    end

    it "does not raise when totals are all zero" do
      report_data[:totals] = {
        gross_wages: 0, withholding_tax: 0,
        social_security_employee: 0, social_security_employer: 0,
        medicare_employee: 0, medicare_employer: 0,
        total_employment_taxes: 0
      }
      expect { generator.generate }.not_to raise_error
    end

    it "does not raise with nil period fields" do
      report_data[:period] = {}
      expect { generator.generate }.not_to raise_error
    end

    it "does not raise with nil totals" do
      report_data[:totals] = nil
      expect { generator.generate }.not_to raise_error
    end

    it "does not raise without a quarter (full-year report)" do
      report_data[:period][:quarter] = nil
      expect { generator.generate }.not_to raise_error
    end
  end

  describe "#filename" do
    it "includes year and quarter" do
      expect(generator.filename).to eq("tax_summary_2025_q1.pdf")
    end

    it "omits quarter suffix when nil" do
      report_data[:period][:quarter] = nil
      expect(generator.filename).to eq("tax_summary_2025.pdf")
    end

    it "falls back gracefully when period is missing" do
      report_data[:period] = {}
      expect(generator.filename).to eq("tax_summary_unknown.pdf")
    end
  end
end
