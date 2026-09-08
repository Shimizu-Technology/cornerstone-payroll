# frozen_string_literal: true

class CreatePayrollFilingResponsibilities < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_filing_responsibilities do |t|
      t.references :company, null: false, foreign_key: true
      t.references :reviewed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :reviewed_by_name, null: false
      t.string :reviewed_by_email, null: false
      t.string :reviewed_by_role, null: false
      t.integer :tax_year, null: false
      t.integer :quarter
      t.string :filing_type, null: false
      t.string :responsible_party, null: false
      t.string :imported_payroll_inclusion, null: false
      t.date :source_cutoff_date
      t.datetime :reviewed_at, null: false
      t.text :notes

      t.timestamps
    end

    add_index :payroll_filing_responsibilities,
              %i[company_id tax_year quarter filing_type],
              unique: true,
              where: "quarter IS NOT NULL",
              name: "idx_payroll_filing_responsibilities_quarterly"
    add_index :payroll_filing_responsibilities,
              %i[company_id tax_year filing_type],
              unique: true,
              where: "quarter IS NULL",
              name: "idx_payroll_filing_responsibilities_annual"
    add_check_constraint :payroll_filing_responsibilities,
                         "tax_year BETWEEN 2000 AND 2200",
                         name: "payroll_filing_responsibilities_year_check"
    add_check_constraint :payroll_filing_responsibilities,
                         "filing_type IN ('form_941', 'guam_withholding', 'swica', 'w2_gu')",
                         name: "payroll_filing_responsibilities_type_check"
    add_check_constraint :payroll_filing_responsibilities,
                         <<~SQL.squish,
                           (filing_type = 'w2_gu' AND quarter IS NULL)
                           OR
                           (filing_type IN ('form_941', 'guam_withholding', 'swica') AND quarter BETWEEN 1 AND 4)
                         SQL
                         name: "payroll_filing_responsibilities_period_check"
    add_check_constraint :payroll_filing_responsibilities,
                         "responsible_party IN ('external_provider', 'cornerstone')",
                         name: "payroll_filing_responsibilities_party_check"
    add_check_constraint :payroll_filing_responsibilities,
                         "imported_payroll_inclusion IN ('included', 'excluded')",
                         name: "payroll_filing_responsibilities_inclusion_check"
  end
end
