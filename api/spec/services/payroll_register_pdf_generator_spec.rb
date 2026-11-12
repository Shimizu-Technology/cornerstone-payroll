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
        total_hours: 80.0,
        total_overtime_hours: 2.0,
        total_gross: 2000.00,
        total_bonus: 100.00,
        total_withholding: 150.00,
        total_social_security: 124.00,
        total_medicare: 29.00,
        total_retirement: 80.00,
        total_straight_loan_deductions: 25.00,
        total_installment_loan_payments: 50.00,
        total_employer_contributions: 60.00,
        total_employer_payroll_cost: 2_213.00,
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
          overtime_hours: 2.0,
          bonus: 100.00,
          gross_pay: 2000.00,
          withholding_tax: 150.00,
          social_security_tax: 124.00,
          medicare_tax: 29.00,
          retirement_payment: 80.00,
          straight_loan_deduction: 25.00,
          installment_loan_payment: 50.00,
          employer_contributions_total: 60.00,
          employer_payroll_cost: 2_213.00,
          total_deductions: 383.00,
          net_pay: 1617.00,
          check_number: "10001",
          payroll_adjustments: [
            {
              label: "Employee Loan",
              treatment: "post_tax_deduction",
              source: "employee_default",
              amount: 50.00
            }
          ],
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
    it "prints accented and non-Latin employee names" do
      template = report_data[:employees].first
      report_data[:employees] = UnicodePdfNames::WORKERS.each_with_index.map do |worker, index|
        template.deep_dup.merge(employee_id: index + 1, employee_name: "#{worker[:first_name]} #{worker[:last_name]}")
      end
      report_data[:meta][:company_name] = "Hagåtña Café"

      text = unicode_pdf_text(generator.generate)
      expect(text).to include(*UnicodePdfNames::TOKENS)
    end

    it "groups currency with thousands separators" do
      report_data[:employees].first[:payroll_field_entries].first[:amount] = 1216.35
      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")
      expect(text).to include("$1,216.35")
      expect(text).not_to include("$1216.35", "Shift Bonus [")
    end

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

    it "keeps distinct same-name payroll fields separate in PDF totals" do
      report_data[:employees].first[:payroll_field_entries] = [
        { id: 11, payroll_field_definition_id: 21, label: "Loan", kind: "deduction", tax_treatment: "post_tax_deduction", amount: BigDecimal("12"), employee_paid: true, employer_paid: false },
        { id: 12, payroll_field_definition_id: 22, label: "Loan", kind: "deduction", tax_treatment: "post_tax_deduction", amount: BigDecimal("7"), employee_paid: true, employer_paid: false }
      ]

      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Loan (1)", "Loan (2)", "$12.00", "$7.00")
      expect(text).not_to include("[field #", "[entry #")
    end

    [ :payroll_field_entries, :payroll_adjustments ].each do |collection|
      it "avoids literal numbered labels in #{collection} headers and totals" do
        report_data[:employees].first[collection] = [ "Loan", "Loan", "Loan (1)", "Loan (2)" ].each_with_index.map do |label, index|
          { id: index + 11, payroll_field_definition_id: index + 21, payroll_item_id: 10, position: index,
            label: label, kind: "deduction", tax_treatment: "post_tax_deduction", treatment: "post_tax_deduction",
            source: "manual", amount: BigDecimal((index + 11).to_s), employee_paid: true, employer_paid: false }
        end
        columns_method, totals_method = collection == :payroll_field_entries ?
          [ :payroll_field_columns, :payroll_field_total_rows ] : [ :payroll_adjustment_columns, :payroll_adjustment_total_rows ]

        labels = generator.send(columns_method).map { |column| column[:label] }
        expect(labels).to contain_exactly("Loan (3)", "Loan (4)", "Loan (1)", "Loan (2)")
        expect(generator.send(totals_method).map { |row| row[1] }).to contain_exactly(*labels)
        text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")
        { "Loan (3)" => "$11.00", "Loan (4)" => "$12.00", "Loan (1)" => "$13.00", "Loan (2)" => "$14.00" }.each do |label, amount|
          expect(text).to match(/#{Regexp.escape(label)}[^\n]*#{Regexp.escape(amount)}/)
        end
      end
    end

    it "reserves literal labels across fields and adjustments" do
      report_data[:employees].first[:payroll_field_entries] = [ 21, 22 ].map do |id|
        { payroll_field_definition_id: id, label: "Loan", kind: "deduction", tax_treatment: "post_tax_deduction", amount: 10 }
      end
      report_data[:employees].first[:payroll_adjustments] = [
        { payroll_item_id: 10, position: 0, label: "Loan (1)", treatment: "post_tax_deduction", source: "manual", amount: 5 }
      ]

      labels = (generator.send(:payroll_field_columns) + generator.send(:payroll_adjustment_columns)).map { |column| column[:label] }
      expect(labels).to contain_exactly("Loan (2)", "Loan (3)", "Loan (1)")
    end

    it "renders named payroll fields beside each worker before the reconciliation summary" do
      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Payroll Fields by Worker", "Alice Terlaje")
    end

    it "renders Mark's requested report totals and split loan labels" do
      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Regular Hours", "80.00", "Overtime Hours", "2.00", "Bonus", "$100.00")
      expect(text).to include("Straight Loans", "$25.00", "Installment Loans", "$50.00")
      expect(text).to include("Employer Contributions", "$60.00", "Employer Payroll Cost", "$2,213.00")
    end

    it "renders source-aware recurring and manual adjustments by worker" do
      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Recurring and Manual Adjustments by Worker", "Employee Loan")
      expect(text).to include("Employee setup", "Post tax deduction", "$50.00")
    end

    it "renders 1099 contractors in a separate detail section" do
      report_data[:contractors] = [
        {
          employee_id: 2,
          employee_name: "Kai Santos",
          employment_type: "contractor",
          hours_worked: 20,
          gross_pay: 600,
          total_deductions: 0,
          net_pay: 600,
          check_number: "1099-1",
          payroll_adjustments: [],
          payroll_field_entries: []
        }
      ]
      report_data[:summary].merge!(contractor_count: 1, contractor_total_gross: 600, contractor_total_net: 600)

      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("W-2 Employee Detail", "Alice Terlaje")
      expect(text).to include("1099 Contractor Detail", "Kai Santos", "$600.00")
      expect(text).to include("Contractor payments are reported separately")
    end

    it "keeps same-name adjustment totals separate without exposing database IDs" do
      report_data[:employees].first[:payroll_adjustments] = [
        { payroll_item_id: 10, position: 0, label: "Allowance", treatment: "taxable_addition", source: "manual", amount: BigDecimal("12") },
        { payroll_item_id: 11, position: 0, label: "Allowance", treatment: "taxable_addition", source: "manual", amount: BigDecimal("7") }
      ]

      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Allowance (1)", "Allowance (2)", "$12.00", "$7.00")
      expect(text).not_to include("[10/1]", "[11/1]")
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
