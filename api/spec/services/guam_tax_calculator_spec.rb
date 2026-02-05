# frozen_string_literal: true

require "rails_helper"

RSpec.describe GuamTaxCalculator do
  let!(:tax_table) { create(:tax_table) }

  describe "#calculate" do
    subject(:calculator) do
      described_class.new(
        tax_year: 2024,
        filing_status: "single",
        pay_frequency: "biweekly",
        allowances: 0
      )
    end

    context "with low income (no withholding bracket)" do
      it "calculates zero withholding" do
        result = calculator.calculate(gross_pay: 500.00)

        expect(result[:withholding]).to eq(0.00)
        expect(result[:social_security]).to eq(31.00)  # 500 * 0.062
        expect(result[:medicare]).to eq(7.25)          # 500 * 0.0145
      end
    end

    context "with income in 10% bracket" do
      it "calculates correct withholding" do
        result = calculator.calculate(gross_pay: 800.00)

        # Taxable income = 800
        # Bracket: 562 - 1007.99, rate 10%, threshold 562
        # Withholding = (800 - 562) * 0.10 = 23.80
        expect(result[:withholding]).to eq(23.80)
        expect(result[:social_security]).to eq(49.60)  # 800 * 0.062
        expect(result[:medicare]).to eq(11.60)         # 800 * 0.0145
      end
    end

    context "with income in 12% bracket" do
      it "calculates correct withholding" do
        result = calculator.calculate(gross_pay: 1500.00)

        # Taxable income = 1500
        # Bracket: 1008 - 2374.99, base_tax 44.60, rate 12%, threshold 1008
        # Withholding = 44.60 + (1500 - 1008) * 0.12 = 44.60 + 59.04 = 103.64
        expect(result[:withholding]).to eq(103.64)
        expect(result[:social_security]).to eq(93.00)   # 1500 * 0.062
        expect(result[:medicare]).to eq(21.75)          # 1500 * 0.0145
      end
    end

    # Validation test case from AGENT_INSTRUCTIONS.md
    context "with 56.48 hours @ $9.25 single filing (validation case)" do
      it "calculates expected values" do
        # Gross = 56.48 * 9.25 = 522.44
        result = calculator.calculate(gross_pay: 522.44)

        expect(result[:withholding]).to eq(0.00)  # Below $562 threshold
        expect(result[:social_security]).to eq(32.39)  # 522.44 * 0.062 = 32.39
        expect(result[:medicare]).to eq(7.58)          # 522.44 * 0.0145 = 7.5754 ≈ 7.58
      end
    end
  end

  describe "#calculate_social_security" do
    let!(:tax_table) { create(:tax_table, ss_wage_base: 168_600) }

    subject(:calculator) do
      described_class.new(
        tax_year: 2024,
        filing_status: "single",
        pay_frequency: "biweekly",
        allowances: 0
      )
    end

    context "when YTD is below wage base" do
      it "withholds full amount" do
        result = calculator.calculate(gross_pay: 3000.00, ytd_gross: 100_000)

        expect(result[:social_security]).to eq(186.00)  # 3000 * 0.062
      end
    end

    context "when YTD reaches wage base this period" do
      it "withholds only up to the cap" do
        # YTD = 167,000, Gross = 3,000
        # Remaining room under cap = 168,600 - 167,000 = 1,600
        # SS = 1,600 * 0.062 = 99.20
        result = calculator.calculate(gross_pay: 3000.00, ytd_gross: 167_000)

        expect(result[:social_security]).to eq(99.20)
      end
    end

    context "when YTD is already at wage base" do
      it "withholds zero" do
        result = calculator.calculate(gross_pay: 3000.00, ytd_gross: 168_600)

        expect(result[:social_security]).to eq(0.00)
      end
    end

    context "when YTD is above wage base" do
      it "withholds zero" do
        result = calculator.calculate(gross_pay: 3000.00, ytd_gross: 200_000)

        expect(result[:social_security]).to eq(0.00)
      end
    end
  end

  describe "#calculate_medicare" do
    let!(:tax_table) do
      create(:tax_table,
        medicare_rate: 0.0145,
        additional_medicare_rate: 0.009,
        additional_medicare_threshold: 200_000
      )
    end

    subject(:calculator) do
      described_class.new(
        tax_year: 2024,
        filing_status: "single",
        pay_frequency: "biweekly",
        allowances: 0
      )
    end

    context "when YTD is below Additional Medicare threshold" do
      it "withholds base rate only" do
        result = calculator.calculate(gross_pay: 3000.00, ytd_gross: 100_000)

        expect(result[:medicare]).to eq(43.50)  # 3000 * 0.0145
      end
    end

    context "when YTD crosses Additional Medicare threshold this period" do
      it "withholds additional rate on portion over threshold" do
        # YTD = 199,000, Gross = 3,000
        # Total = 202,000
        # Amount over threshold = 2,000
        # Base Medicare = 3,000 * 0.0145 = 43.50
        # Additional = 2,000 * 0.009 = 18.00
        # Total = 61.50
        result = calculator.calculate(gross_pay: 3000.00, ytd_gross: 199_000)

        expect(result[:medicare]).to eq(61.50)
      end
    end

    context "when YTD is already above Additional Medicare threshold" do
      it "withholds additional rate on full paycheck" do
        # YTD = 250,000 (already over threshold)
        # Base Medicare = 3,000 * 0.0145 = 43.50
        # Additional = 3,000 * 0.009 = 27.00
        # Total = 70.50
        result = calculator.calculate(gross_pay: 3000.00, ytd_gross: 250_000)

        expect(result[:medicare]).to eq(70.50)
      end
    end
  end

  describe "#calculate_withholding with allowances" do
    let!(:tax_table) { create(:tax_table, allowance_amount: 192.31) }

    context "with 1 allowance" do
      subject(:calculator) do
        described_class.new(
          tax_year: 2024,
          filing_status: "single",
          pay_frequency: "biweekly",
          allowances: 1
        )
      end

      it "reduces taxable income by allowance amount" do
        # Gross = 800, Allowance = 192.31
        # Taxable = 800 - 192.31 = 607.69
        # Bracket: 562 - 1007.99, rate 10%, threshold 562
        # Withholding = (607.69 - 562) * 0.10 = 4.57
        result = calculator.calculate(gross_pay: 800.00)

        expect(result[:withholding]).to eq(4.57)
      end
    end

    context "with 2 allowances pushing income below threshold" do
      subject(:calculator) do
        described_class.new(
          tax_year: 2024,
          filing_status: "single",
          pay_frequency: "biweekly",
          allowances: 2
        )
      end

      it "calculates zero withholding" do
        # Gross = 800, Allowance = 192.31 * 2 = 384.62
        # Taxable = 800 - 384.62 = 415.38
        # Below $562 threshold = $0 withholding
        result = calculator.calculate(gross_pay: 800.00)

        expect(result[:withholding]).to eq(0.00)
      end
    end
  end

  describe "married filing status" do
    let!(:married_tax_table) { create(:tax_table, :married) }

    subject(:calculator) do
      described_class.new(
        tax_year: 2024,
        filing_status: "married",
        pay_frequency: "biweekly",
        allowances: 0
      )
    end

    it "uses married tax brackets" do
      # Income of 1000 is in 0% bracket for married (up to 1122.99)
      result = calculator.calculate(gross_pay: 1000.00)

      expect(result[:withholding]).to eq(0.00)
    end

    it "calculates withholding in 10% bracket" do
      # Income of 1500 for married
      # Bracket: 1123 - 2014.99, rate 10%, threshold 1123
      # Withholding = (1500 - 1123) * 0.10 = 37.70
      result = calculator.calculate(gross_pay: 1500.00)

      expect(result[:withholding]).to eq(37.70)
    end
  end
end
