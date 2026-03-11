# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollRegisterPdfGenerator do
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
        employee_count: 1,
        total_gross: 2000.00,
        total_withholding: 150.00,
        total_social_security: 124.00,
        total_medicare: 29.00,
        total_retirement: 80.00,
        total_deductions: 383.00,
        total_net: 1617.00
      },
      employees: [
        {
          employee_id: 1,
          employee_name: "Alice Terlaje",
          employment_type: "hourly",
          pay_rate: 20.00,
          hours_worked: 80.0,
          overtime_hours: 0.0,
          gross_pay: 2000.00,
          withholding_tax: 150.00,
          social_security_tax: 124.00,
          medicare_tax: 29.00,
          retirement_payment: 80.00,
          total_deductions: 383.00,
          net_pay: 1617.00,
          check_number: "10001"
        }
      ]
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

    it "does not raise for a report with no employees" do
      report_data[:employees] = []
      report_data[:summary][:employee_count] = 0
      expect { generator.generate }.not_to raise_error
    end

    it "does not raise for nil pay_period fields" do
      report_data[:pay_period] = {}
      expect { generator.generate }.not_to raise_error
    end

    it "does not raise for nil summary" do
      report_data[:summary] = nil
      expect { generator.generate }.not_to raise_error
    end
  end

  describe "#filename" do
    it "includes the pay period date range" do
      expect(generator.filename).to eq("payroll_register_2025-03-01_to_2025-03-14.pdf")
    end

    it "falls back to unknown_period when dates are missing" do
      report_data[:pay_period] = {}
      expect(generator.filename).to eq("payroll_register_unknown_period.pdf")
    end
  end
end
