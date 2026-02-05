# frozen_string_literal: true

class CreateCompanyYtdTotals < ActiveRecord::Migration[8.1]
  def change
    create_table :company_ytd_totals do |t|
      t.references :company, null: false, foreign_key: true
      t.integer :year, null: false

      # Pay totals
      t.decimal :gross_pay, precision: 16, scale: 2, default: 0
      t.decimal :net_pay, precision: 16, scale: 2, default: 0

      # Tax totals (employee withholding)
      t.decimal :withholding_tax, precision: 16, scale: 2, default: 0
      t.decimal :social_security_tax, precision: 16, scale: 2, default: 0
      t.decimal :medicare_tax, precision: 16, scale: 2, default: 0

      # Employer tax contributions
      t.decimal :employer_social_security, precision: 16, scale: 2, default: 0
      t.decimal :employer_medicare, precision: 16, scale: 2, default: 0

      # Employee count
      t.integer :total_employees, default: 0
      t.integer :active_employees, default: 0

      t.timestamps
    end

    add_index :company_ytd_totals, [ :company_id, :year ], unique: true
  end
end
