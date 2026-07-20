# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

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
          check_number: "10001",
          payroll_field_entries: [
            {
              label: "Shift Bonus",
              kind: "addition",
              tax_treatment: "taxable_addition",
              amount: 25.00,
              employee_paid: false,
              employer_paid: false
            },
            {
              label: "Employer Benefit",
              kind: "employer_contribution",
              tax_treatment: "employer_contribution",
              amount: 50.00,
              employee_paid: false,
              employer_paid: true
            }
          ]
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

    it "hides custom adjustment columns when the report has no custom adjustments" do
      labels = generator.send(:employee_table_columns).map { |column| column[:label] }

      expect(labels).not_to include("Custom Earn", "Custom Ded")
    end

    it "shows custom adjustment columns when the report has custom adjustments" do
      report_data[:summary][:total_custom_earnings] = 25.00
      report_data[:summary][:total_custom_deductions] = 10.00
      report_data[:employees].first[:custom_earnings_total] = 25.00
      report_data[:employees].first[:custom_deductions_total] = 10.00

      labels = generator.send(:employee_table_columns).map { |column| column[:label] }

      expect(labels).to include("Custom Earn", "Custom Ded")
    end

    it "renders payroll field treatment totals for reconciliation" do
      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Payroll Fields", "Shift Bonus", "Taxable addition", "$25.00")
      expect(text).to include("Employer Benefit", "Employer contribution", "$50.00")
    end

    it "renders named payroll fields beside each worker before the reconciliation summary" do
      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Payroll Fields by Worker", "Alice Terlaje")
    end

    it "distinguishes an assigned zero amount from a field that was not assigned" do
      report_data[:employees].first[:payroll_field_entries].first[:amount] = 0
      report_data[:employees] << report_data[:employees].first.merge(
        employee_id: 2,
        employee_name: "Bob Meno",
        payroll_field_entries: []
      )

      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("$0.00", "Bob Meno", "—")
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
