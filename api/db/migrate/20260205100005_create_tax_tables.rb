# frozen_string_literal: true

class CreateTaxTables < ActiveRecord::Migration[8.1]
  def change
    create_table :tax_tables do |t|
      t.integer :tax_year, null: false
      t.string :filing_status, null: false # single, married, head_of_household
      t.string :pay_frequency, null: false # biweekly, weekly, semimonthly, monthly

      # Withholding brackets stored as JSONB array
      # Each bracket: { min_income, max_income, base_tax, rate, threshold }
      t.jsonb :bracket_data, null: false, default: []

      # Social Security
      t.decimal :ss_rate, precision: 6, scale: 5, null: false, default: 0.062
      t.decimal :ss_wage_base, precision: 12, scale: 2, null: false # e.g., 176100 for 2025

      # Medicare
      t.decimal :medicare_rate, precision: 6, scale: 5, null: false, default: 0.0145
      t.decimal :additional_medicare_rate, precision: 6, scale: 5, default: 0.009 # 0.9%
      t.decimal :additional_medicare_threshold, precision: 12, scale: 2, default: 200000 # $200K single

      # Allowance amount per period
      t.decimal :allowance_amount, precision: 10, scale: 2

      t.timestamps
    end

    add_index :tax_tables, [ :tax_year, :filing_status, :pay_frequency ], unique: true, name: "idx_tax_tables_year_status_frequency"
  end
end
