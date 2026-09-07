# frozen_string_literal: true

module QuickbooksHistory
  module WageDerivation
    module_function

    # Rows must contain every paycheck for each employee_key in the capping
    # period. Splitting an employee's rows across calls would cap each subset.
    def call(rows:, social_security_wage_base:)
      raise ArgumentError, "social_security_wage_base is required" if social_security_wage_base.nil?

      normalized = rows.map { |row| row.to_h.symbolize_keys }
      fica_by_employee = normalized.group_by { |row| row.fetch(:employee_key) }.transform_values do |employee_rows|
        employee_rows.sum(0.to_d) do |row|
          decimal(row, :gross_pay) - decimal(row, :non_taxable_earnings) - decimal(row, :fica_exempt_pretax_deductions)
        end.round(2)
      end
      fica_total = fica_by_employee.values.sum(0.to_d).round(2)
      social_security_taxable = fica_by_employee.values.sum(0.to_d) do |wages|
        [ wages, social_security_wage_base.to_d ].min
      end.round(2)

      {
        fit_taxable_wages: normalized.sum(0.to_d) do |row|
          decimal(row, :gross_pay) - decimal(row, :pretax_deductions) - decimal(row, :non_taxable_earnings)
        end.round(2),
        fica_total_wages: fica_total,
        social_security_excess_wages: (fica_total - social_security_taxable).round(2),
        social_security_taxable_wages: social_security_taxable,
        medicare_taxable_wages: fica_total
      }
    end

    def decimal(row, key)
      value = row[key]
      value.nil? ? 0.to_d : BigDecimal(value.to_s)
    end
    private_class_method :decimal
  end
end
