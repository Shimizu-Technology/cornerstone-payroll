# frozen_string_literal: true

class CreateEmployeeW4Elections < ActiveRecord::Migration[8.0]
  def up
    create_table :employee_w4_elections do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :employee, null: false, foreign_key: { on_delete: :restrict }
      t.references :created_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.date :effective_on, null: false
      t.string :filing_status, null: false
      t.integer :allowances, null: false, default: 0
      t.decimal :additional_withholding, precision: 10, scale: 2, null: false, default: 0
      t.decimal :w4_dependent_credit, precision: 10, scale: 2, null: false, default: 0
      t.boolean :w4_step2_multiple_jobs, null: false, default: false
      t.decimal :w4_step4a_other_income, precision: 10, scale: 2, null: false, default: 0
      t.decimal :w4_step4b_deductions, precision: 10, scale: 2, null: false, default: 0
      t.integer :w4_form_version, null: false, default: 2020
      t.string :source, null: false
      t.text :reason, null: false
      t.timestamps
    end

    add_index :employee_w4_elections,
      [ :employee_id, :effective_on, :created_at ],
      name: "idx_employee_w4_elections_effective"
    add_index :employee_w4_elections,
      [ :company_id, :effective_on ],
      name: "idx_employee_w4_elections_company_effective"
    add_check_constraint :employee_w4_elections,
      "filing_status IN ('single', 'married', 'married_separate', 'head_of_household')",
      name: "employee_w4_elections_filing_status_check"
    add_check_constraint :employee_w4_elections,
      "source IN ('staff', 'client_approved', 'employee_creation', 'legacy_profile', 'quickbooks_history')",
      name: "employee_w4_elections_source_check"

    execute <<~SQL
      INSERT INTO employee_w4_elections (
        company_id,
        employee_id,
        effective_on,
        CASE
          WHEN filing_status IN ('single', 'married', 'married_separate', 'head_of_household') THEN filing_status
          ELSE 'single'
        END,
        allowances,
        additional_withholding,
        w4_dependent_credit,
        w4_step2_multiple_jobs,
        w4_step4a_other_income,
        w4_step4b_deductions,
        w4_form_version,
        source,
        reason,
        created_at,
        updated_at
      )
      SELECT
        company_id,
        id,
        COALESCE(w4_effective_on, hire_date, created_at::date),
        filing_status,
        COALESCE(allowances, 0),
        COALESCE(additional_withholding, 0),
        COALESCE(w4_dependent_credit, 0),
        COALESCE(w4_step2_multiple_jobs, FALSE),
        COALESCE(w4_step4a_other_income, 0),
        COALESCE(w4_step4b_deductions, 0),
        COALESCE(w4_form_version, 2020),
        CASE WHEN configuration_source = 'quickbooks_history' THEN 'quickbooks_history' ELSE 'legacy_profile' END,
        'Initial W-4 election migrated from the employee profile',
        NOW(),
        NOW()
      FROM employees
      WHERE employment_type IN ('hourly', 'salary')
    SQL
  end

  def down
    drop_table :employee_w4_elections
  end
end
