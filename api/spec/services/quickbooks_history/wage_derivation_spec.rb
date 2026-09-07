# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::WageDerivation do
  it "normalizes present nil money fields to zero" do
    result = described_class.call(
      rows: [
        {
          employee_key: "worker-1",
          gross_pay: 100.to_d,
          pretax_deductions: nil,
          non_taxable_earnings: nil,
          fica_exempt_pretax_deductions: nil
        }
      ],
      social_security_wage_base: 176_100.to_d
    )

    expect(result).to include(
      fit_taxable_wages: 100.to_d,
      fica_total_wages: 100.to_d,
      social_security_taxable_wages: 100.to_d,
      medicare_taxable_wages: 100.to_d
    )
  end

  it "requires an explicit Social Security wage base" do
    expect { described_class.call(rows: [], social_security_wage_base: nil) }
      .to raise_error(ArgumentError, /wage_base is required/)
  end

  it "derives FIT, FICA, Medicare, and the Social Security cap per employee" do
    result = described_class.call(
      rows: [
        {
          employee_key: "alice",
          gross_pay: 120,
          pretax_deductions: 10,
          non_taxable_earnings: 5,
          fica_exempt_pretax_deductions: 3
        },
        {
          employee_key: "alice",
          gross_pay: 20,
          pretax_deductions: 0,
          non_taxable_earnings: 0,
          fica_exempt_pretax_deductions: 0
        },
        {
          employee_key: "bob",
          gross_pay: 80,
          pretax_deductions: 5,
          non_taxable_earnings: 0,
          fica_exempt_pretax_deductions: 0
        }
      ],
      social_security_wage_base: 100
    )

    expect(result).to eq(
      fit_taxable_wages: 200.to_d,
      fica_total_wages: 212.to_d,
      social_security_excess_wages: 32.to_d,
      social_security_taxable_wages: 180.to_d,
      medicare_taxable_wages: 212.to_d
    )
  end

  it "has no Social Security excess when cumulative wages equal the wage base" do
    result = described_class.call(
      rows: [ { employee_key: "alice", gross_pay: 100 } ],
      social_security_wage_base: 100
    )

    expect(result).to include(
      social_security_taxable_wages: 100.to_d,
      social_security_excess_wages: 0.to_d
    )
  end

  it "nets reversal rows before applying the per-employee Social Security cap" do
    result = described_class.call(
      rows: [
        { employee_key: "alice", gross_pay: 120 },
        { employee_key: "alice", gross_pay: -20 }
      ],
      social_security_wage_base: 100
    )

    expect(result).to include(
      social_security_taxable_wages: 100.to_d,
      social_security_excess_wages: 0.to_d
    )
  end

  it "preserves a fully reversed employee without inventing Social Security excess" do
    result = described_class.call(
      rows: [ { employee_key: "alice", gross_pay: -100 } ],
      social_security_wage_base: 100
    )

    expect(result).to include(
      fica_total_wages: -100.to_d,
      social_security_taxable_wages: -100.to_d,
      social_security_excess_wages: 0.to_d,
      medicare_taxable_wages: -100.to_d
    )
  end
end
