# frozen_string_literal: true

require "rails_helper"

RSpec.describe UnifiedPayrollReporting do
  FinancialRow = Struct.new(
    :hours_total,
    :hours_breakdown,
    :gross_pay,
    :earnings_breakdown,
    :employer_contributions,
    :total_payroll_cost,
    :federal_income_tax,
    :social_security_tax,
    :medicare_tax,
    :pretax_deduction_breakdown,
    :after_tax_deduction_breakdown,
    :employer_taxes,
    :employer_tax_breakdown,
    :employer_contribution_breakdown,
    :employee_taxes,
    :after_tax_deductions,
    :pretax_deductions,
    :net_pay,
    keyword_init: true
  )

  describe "historical employer cost classification" do
    it "separates employer taxes, 401(k) matches, and unclassified contributions across source and adjustments" do
      source = FinancialRow.new(
        hours_total: 40,
        hours_breakdown: [],
        gross_pay: 1_000,
        earnings_breakdown: [],
        employer_contributions: 55,
        total_payroll_cost: 1_131.50,
        federal_income_tax: 100,
        social_security_tax: 62,
        medicare_tax: 14.50,
        pretax_deduction_breakdown: [],
        after_tax_deduction_breakdown: [],
        employer_taxes: 76.50,
        employer_tax_breakdown: [
          { "label" => "Social Security Employer", "amount" => "62.00" },
          { "label" => "Medicare Employer", "amount" => "14.50" }
        ],
        employer_contribution_breakdown: [
          { "label" => "401(k) Employer Match", "amount" => "40.00" },
          { "label" => "Roth 401(k) Match", "amount" => "10.00" },
          { "label" => "Employer Health", "amount" => "5.00" }
        ],
        employee_taxes: 176.50,
        after_tax_deductions: 0,
        pretax_deductions: 0,
        net_pay: 823.50
      )
      adjustment = FinancialRow.new(
        hours_total: 4,
        hours_breakdown: [],
        gross_pay: 100,
        earnings_breakdown: [],
        employer_contributions: 5,
        total_payroll_cost: 112.65,
        federal_income_tax: 10,
        social_security_tax: 6.20,
        medicare_tax: 1.45,
        pretax_deduction_breakdown: [],
        after_tax_deduction_breakdown: [],
        employer_taxes: 7.65,
        employer_tax_breakdown: [
          { "label" => "SS", "amount" => "6.20" },
          { "label" => "Med", "amount" => "1.45" }
        ],
        employer_contribution_breakdown: [
          { "label" => "401(k) Employer Match", "amount" => "5.00" }
        ],
        employee_taxes: 17.65,
        after_tax_deductions: 0,
        pretax_deductions: 0,
        net_pay: 82.35
      )

      totals = described_class.new(company_id: 1, period: instance_double(PayrollReportingPeriod))
        .send(:historical_totals, [ source ], [ adjustment ])

      expect(totals).to include(
        employer_social_security_tax: 68.20,
        employer_medicare_tax: 15.95,
        other_employer_taxes: 0.0,
        employer_taxes_total: 84.15,
        employer_traditional_401k_match: 45.0,
        employer_roth_401k_match: 10.0,
        other_employer_contributions: 5.0,
        employer_contributions: 60.0,
        employer_taxes_and_contributions_total: 144.15,
        employer_payroll_cost: 1_244.15
      )
    end

    it "keeps an ambiguous historical employer tax in the other-tax bucket" do
      source = FinancialRow.new(
        hours_total: 0,
        hours_breakdown: [],
        gross_pay: 100,
        earnings_breakdown: [],
        employer_contributions: 0,
        total_payroll_cost: 107,
        federal_income_tax: 0,
        social_security_tax: 0,
        medicare_tax: 0,
        pretax_deduction_breakdown: [],
        after_tax_deduction_breakdown: [],
        employer_taxes: 7,
        employer_tax_breakdown: [ { "label" => "Employer FICA", "amount" => "7.00" } ],
        employer_contribution_breakdown: [],
        employee_taxes: 0,
        after_tax_deductions: 0,
        pretax_deductions: 0,
        net_pay: 100
      )

      totals = described_class.new(company_id: 1, period: instance_double(PayrollReportingPeriod))
        .send(:historical_totals, [ source ])

      expect(totals).to include(
        employer_social_security_tax: 0.0,
        employer_medicare_tax: 0.0,
        other_employer_taxes: 7.0,
        employer_taxes_total: 7.0
      )
    end
  end
end
