# frozen_string_literal: true

class AddPhaseZeroPayrollComplianceFoundations < ActiveRecord::Migration[8.1]
  def up
    add_column :employees, :w4_form_version, :integer, null: false, default: 2020
    add_column :employees, :w4_effective_on, :date
    # Preserve the originally entered legacy status for audit and rollback.
    # Employee and both tax engines normalize aliases at calculation boundaries.

    add_reference :payroll_items,
                  :annual_tax_config,
                  null: true,
                  foreign_key: { on_delete: :restrict }
    add_column :payroll_items, :fit_taxable_wages, :decimal, precision: 14, scale: 2
    add_column :payroll_items, :social_security_taxable_wages, :decimal, precision: 14, scale: 2
    add_column :payroll_items, :social_security_taxable_tips, :decimal, precision: 14, scale: 2
    add_column :payroll_items, :medicare_taxable_wages, :decimal, precision: 14, scale: 2
    add_column :payroll_items, :additional_medicare_taxable_wages, :decimal, precision: 14, scale: 2
    add_column :payroll_items, :additional_medicare_tax, :decimal, precision: 12, scale: 2
    add_column :payroll_items, :cash_tips_reported, :decimal, precision: 14, scale: 2
    add_column :payroll_items, :service_charge_wages, :decimal, precision: 14, scale: 2
    add_column :payroll_items, :qualified_overtime_compensation, :decimal, precision: 14, scale: 2
    add_column :payroll_items, :tax_rule_snapshot, :jsonb, null: false, default: {}
    add_index :payroll_items, :tax_rule_snapshot, using: :gin

    create_table :employee_tipped_occupations do |t|
      t.references :employee, null: false, foreign_key: { on_delete: :cascade }
      t.string :occupation_code, null: false, limit: 3
      t.date :effective_from, null: false
      t.date :effective_to
      t.string :source
      t.text :notes
      t.timestamps
    end
    add_index :employee_tipped_occupations,
              [ :employee_id, :occupation_code, :effective_from ],
              unique: true,
              name: "idx_employee_tipped_occupations_unique_start"
    add_check_constraint :employee_tipped_occupations,
                         "occupation_code ~ '^[0-9]{3}$'",
                         name: "employee_tipped_occupation_code_format"
    add_check_constraint :employee_tipped_occupations,
                         "effective_to IS NULL OR effective_to >= effective_from",
                         name: "employee_tipped_occupation_date_order"

    create_table :information_return_thresholds do |t|
      t.string :form_type, null: false
      t.integer :tax_year, null: false
      t.decimal :threshold_amount, precision: 14, scale: 2, null: false
      t.string :source_url, null: false
      t.date :effective_on, null: false
      t.timestamps
    end
    add_index :information_return_thresholds,
              [ :form_type, :tax_year ],
              unique: true,
              name: "idx_information_return_thresholds_form_year"
    add_check_constraint :information_return_thresholds,
                         "threshold_amount >= 0",
                         name: "information_return_threshold_nonnegative"

    seed_information_return_thresholds
  end

  def down
    drop_table :information_return_thresholds
    drop_table :employee_tipped_occupations

    remove_index :payroll_items, :tax_rule_snapshot
    remove_column :payroll_items, :tax_rule_snapshot
    remove_column :payroll_items, :qualified_overtime_compensation
    remove_column :payroll_items, :service_charge_wages
    remove_column :payroll_items, :cash_tips_reported
    remove_column :payroll_items, :additional_medicare_tax
    remove_column :payroll_items, :additional_medicare_taxable_wages
    remove_column :payroll_items, :medicare_taxable_wages
    remove_column :payroll_items, :social_security_taxable_tips
    remove_column :payroll_items, :social_security_taxable_wages
    remove_column :payroll_items, :fit_taxable_wages
    remove_reference :payroll_items, :annual_tax_config, foreign_key: true

    remove_column :employees, :w4_effective_on
    remove_column :employees, :w4_form_version
  end

  private

  def seed_information_return_thresholds
    source_url = "https://www.irs.gov/instructions/i1099mec"
    now = connection.quote(Time.current)

    (2020..2025).each do |tax_year|
      execute <<~SQL.squish
        INSERT INTO information_return_thresholds
          (form_type, tax_year, threshold_amount, source_url, effective_on, created_at, updated_at)
        VALUES
          ('1099_nec', #{tax_year}, 600.00, #{connection.quote(source_url)}, '#{tax_year}-01-01', #{now}, #{now})
        ON CONFLICT (form_type, tax_year) DO NOTHING
      SQL
    end

    execute <<~SQL.squish
      INSERT INTO information_return_thresholds
        (form_type, tax_year, threshold_amount, source_url, effective_on, created_at, updated_at)
      VALUES
        ('1099_nec', 2026, 2000.00, #{connection.quote(source_url)}, '2026-01-01', #{now}, #{now})
      ON CONFLICT (form_type, tax_year) DO NOTHING
    SQL
  end
end
