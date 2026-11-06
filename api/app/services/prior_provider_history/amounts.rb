# frozen_string_literal: true

module PriorProviderHistory
  # Every field is explicit, including a confirmed zero. Never infer wage bases
  # from rounded taxes, or assume that gross is taxable for each tax.
  module Amounts
    FIELDS = %w[
      gross_pay federal_income_tax social_security_tax medicare_tax
      pretax_deductions after_tax_deductions net_pay
      employer_social_security_tax employer_medicare_tax employer_contributions
      fit_taxable_wages social_security_taxable_wages social_security_taxable_tips
      medicare_taxable_wages additional_medicare_taxable_wages
      non_taxable_pay reported_tips tips_paid_out retirement roth_retirement insurance loans
    ].freeze
    REGISTER_FIELDS = %w[gross_pay federal_income_tax social_security_tax medicare_tax deductions net_pay employer_taxes employer_contributions].freeze
    BREAKDOWNS = %w[earnings_breakdown pretax_deduction_breakdown after_tax_deduction_breakdown employer_contribution_breakdown].freeze

    module_function

    def money(value, label)
      string = value.to_s
      unless string.match?(/\A\d{1,10}(?:\.\d{1,2})?\z/)
        raise ArgumentError, "#{label.humanize} requires a nonnegative amount with at most two decimals (confirm zero explicitly)"
      end
      BigDecimal(string)
    end

    def validate!(row)
      values = FIELDS.to_h { |key| [ key, money(row[key], key) ] }
      gross = values.fetch("gross_pay")
      taxes = values.values_at("federal_income_tax", "social_security_tax", "medicare_tax").sum
      deductions = values.values_at("pretax_deductions", "after_tax_deductions").sum
      raise ArgumentError, "Gross less employee taxes and deductions must equal net" unless gross - taxes - deductions == values.fetch("net_pay")
      %w[fit_taxable_wages social_security_taxable_wages social_security_taxable_tips medicare_taxable_wages non_taxable_pay reported_tips].each do |key|
        raise ArgumentError, "#{key.humanize} exceeds gross" if values.fetch(key) > gross
      end
      ss = values.values_at("social_security_taxable_wages", "social_security_taxable_tips").sum
      raise ArgumentError, "SS wages and tips exceed Medicare wages" if ss > values.fetch("medicare_taxable_wages")
      raise ArgumentError, "SS taxable tips exceed reported tips" if values.fetch("social_security_taxable_tips") > values.fetch("reported_tips")
      raise ArgumentError, "Additional Medicare wages exceed Medicare wages" if values.fetch("additional_medicare_taxable_wages") > values.fetch("medicare_taxable_wages")
      raise ArgumentError, "Retirement exceeds pre-tax deductions" if values.fetch("retirement") > values.fetch("pretax_deductions")
      if values.values_at("roth_retirement", "insurance", "loans", "tips_paid_out").sum > values.fetch("after_tax_deductions")
        raise ArgumentError, "Classified post-tax deductions exceed the deduction total"
      end
      breakdown_totals = {
        "earnings_breakdown" => gross,
        "pretax_deduction_breakdown" => values.fetch("pretax_deductions"),
        "after_tax_deduction_breakdown" => values.fetch("after_tax_deductions"),
        "employer_contribution_breakdown" => values.fetch("employer_contributions")
      }
      breakdown_totals.each do |field, expected|
        entries = row[field]
        raise ArgumentError, "#{field.humanize} must contain labeled amounts" unless entries.is_a?(Array) && entries.size <= 100
        actual = entries.sum(0.to_d) do |entry|
          raise ArgumentError, "Every component requires a label" unless entry.is_a?(Hash) && entry["label"].to_s.strip.present? && entry["label"].to_s.length <= 160
          money(entry["amount"], field)
        end
        raise ArgumentError, "#{field.humanize} does not match its total" unless actual == expected
      end
      values
    end

    def totals(rows)
      fields = FIELDS.to_h { |field| [ field, rows.sum(0.to_d) { |row| row.fetch(field).to_d }.round(2).to_s("F") ] }
      fields.merge(
        "deductions" => (fields.fetch("pretax_deductions").to_d + fields.fetch("after_tax_deductions").to_d).to_s("F"),
        "employer_taxes" => (fields.fetch("employer_social_security_tax").to_d + fields.fetch("employer_medicare_tax").to_d).to_s("F")
      )
    end
  end
end
