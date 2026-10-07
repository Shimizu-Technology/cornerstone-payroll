# frozen_string_literal: true

class CompleteRetirementComplianceInputs < ActiveRecord::Migration[8.0]
  def change
    add_column :annual_retirement_limits, :annual_additions_limit, :decimal, precision: 14, scale: 2
    add_column :annual_retirement_limits, :compensation_limit, :decimal, precision: 14, scale: 2
    add_check_constraint :annual_retirement_limits,
      "(annual_additions_limit IS NULL OR annual_additions_limit >= 0) AND (compensation_limit IS NULL OR compensation_limit >= 0)",
      name: "retirement_limits_additional_amounts"

    reversible do |direction|
      direction.up do
        # Only the published 2026 values are supplied. Other years require verification.
        execute <<~SQL
          UPDATE annual_retirement_limits SET annual_additions_limit = 72000.00,
            compensation_limit = 360000.00,
            source_name = 'IRS Notice 2025-67',
            source_url = 'https://www.irs.gov/pub/irs-drop/n-25-67.pdf', updated_at = CURRENT_TIMESTAMP
          WHERE tax_year = 2026
        SQL
      end
    end

    add_column :employee_retirement_elections, :plan_type, :string, null: false, default: "standard_401k"
    add_column :employee_retirement_elections, :limitation_year_type, :string, null: false, default: "calendar"
    add_column :employee_retirement_elections, :related_plan_review_required, :boolean, null: false, default: false
    add_column :employee_retirement_elections, :roth_available, :boolean, null: false, default: false
    add_column :employee_retirement_elections, :employer_roth_available, :boolean, null: false, default: false
    add_column :employee_retirement_elections, :plan_source_reference, :text
    add_column :employee_retirement_elections, :regular_plan_deferral_limit, :decimal, precision: 14, scale: 2

    create_table :employee_retirement_year_inputs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.integer :tax_year, null: false
      t.string :prior_year_wage_status, null: false, default: "unknown"
      # Covered Social Security wages from the applicable sponsoring employer,
      # not Medicare wages or gross wages. Retain the public contract field name.
      t.decimal :prior_year_fica_wages, precision: 14, scale: 2
      t.text :prior_year_wage_source
      %i[external_traditional_deferrals external_roth_deferrals eligible_compensation_before_system
        employer_additions_before_system non_roth_after_tax_before_system].each do |amount|
        t.decimal amount, precision: 14, scale: 2, null: false, default: 0
      end
      t.boolean :opening_balances_verified, null: false, default: false
      t.text :source_reference, null: false
      t.text :reason, null: false
      t.timestamps
    end
    add_index :employee_retirement_year_inputs, [ :employee_id, :tax_year, :created_at ],
      name: "idx_retirement_year_inputs_latest"
    add_check_constraint :employee_retirement_year_inputs, "tax_year BETWEEN 2000 AND 2200", name: "retirement_year_input_year"
    add_check_constraint :employee_retirement_year_inputs,
      "external_traditional_deferrals >= 0 AND external_roth_deferrals >= 0 AND eligible_compensation_before_system >= 0 AND employer_additions_before_system >= 0 AND non_roth_after_tax_before_system >= 0 AND (prior_year_fica_wages IS NULL OR prior_year_fica_wages >= 0)",
      name: "retirement_year_input_amounts"
    add_check_constraint :employee_retirement_year_inputs,
      "prior_year_wage_status IN ('unknown', 'verified', 'no_prior_employer_wages')",
      name: "retirement_year_input_wage_status"
    add_check_constraint :employee_retirement_year_inputs,
      "(prior_year_wage_status = 'unknown' AND prior_year_fica_wages IS NULL) OR (prior_year_wage_status <> 'unknown' AND prior_year_fica_wages IS NOT NULL AND prior_year_wage_source IS NOT NULL AND btrim(prior_year_wage_source) <> '' AND (prior_year_wage_status <> 'no_prior_employer_wages' OR prior_year_fica_wages = 0))",
      name: "retirement_year_input_wage_evidence"
    add_check_constraint :employee_retirement_year_inputs,
      "opening_balances_verified OR (eligible_compensation_before_system = 0 AND employer_additions_before_system = 0 AND non_roth_after_tax_before_system = 0)",
      name: "retirement_year_input_opening_evidence"
    reversible do |direction|
      direction.up { execute append_only_trigger_sql }
      direction.down { execute "DROP FUNCTION IF EXISTS prevent_retirement_year_input_mutation() CASCADE" }
    end
  end

  private

  def append_only_trigger_sql
    <<~SQL
      CREATE OR REPLACE FUNCTION prevent_retirement_year_input_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'employee_retirement_year_inputs are append-only';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER retirement_year_inputs_append_only
      BEFORE UPDATE OR DELETE ON employee_retirement_year_inputs
      FOR EACH ROW EXECUTE FUNCTION prevent_retirement_year_input_mutation();
    SQL
  end
end
