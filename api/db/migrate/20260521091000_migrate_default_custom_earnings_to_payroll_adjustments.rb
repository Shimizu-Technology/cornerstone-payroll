# frozen_string_literal: true

class MigrateDefaultCustomEarningsToPayrollAdjustments < ActiveRecord::Migration[8.1]
  class MigrationEmployee < ActiveRecord::Base
    self.table_name = "employees"
  end

  def up
    MigrationEmployee.reset_column_information

    MigrationEmployee.find_each do |employee|
      legacy_earnings = Array(employee.default_custom_earnings).filter_map do |entry|
        data = entry.is_a?(Hash) ? entry : {}
        label = data["label"].to_s.strip
        amount = BigDecimal(data["amount"].to_s)
        next if label.blank? || amount <= 0 || !amount.finite?

        {
          "label" => label,
          "amount" => amount.round(2).to_f,
          "treatment" => "taxable_addition",
          "active" => true,
          "notes" => "Migrated from legacy recurring custom earnings"
        }
      rescue ArgumentError, FloatDomainError
        nil
      end

      next if legacy_earnings.empty?

      existing_adjustments = Array(employee.default_payroll_adjustments)
      existing_keys = existing_adjustments.map do |adjustment|
        [ adjustment["treatment"].to_s, adjustment["label"].to_s.strip.downcase ]
      end

      additions = legacy_earnings.reject do |adjustment|
        existing_keys.include?([ adjustment["treatment"], adjustment["label"].downcase ])
      end

      employee.update_columns(
        default_payroll_adjustments: existing_adjustments + additions,
        default_custom_earnings: []
      )
    end
  end

  def down
    # Intentionally one-way. Reconstructing legacy custom earnings from taxable
    # payroll adjustments would risk incorrectly moving newly-created taxable
    # adjustments back into the deprecated field.
  end
end
