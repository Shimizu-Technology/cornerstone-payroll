class AddEffectiveDatedRetirementRules < ActiveRecord::Migration[8.0]
  def change
    create_table :annual_retirement_limits do |t|
      t.integer :tax_year, null: false
      t.decimal :elective_deferral_limit, precision: 14, scale: 2, null: false
      t.decimal :catch_up_limit, precision: 14, scale: 2, null: false
      t.decimal :enhanced_catch_up_limit, precision: 14, scale: 2, null: false
      t.decimal :roth_catch_up_wage_threshold, precision: 14, scale: 2, null: false
      t.string :source_name, null: false
      t.string :source_url, null: false
      t.timestamps
    end
    add_index :annual_retirement_limits, :tax_year, unique: true

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          INSERT INTO annual_retirement_limits
            (tax_year, elective_deferral_limit, catch_up_limit, enhanced_catch_up_limit,
             roth_catch_up_wage_threshold, source_name, source_url, created_at, updated_at)
          VALUES
            (2026, 24500.00, 8000.00, 11250.00, 150000.00,
             'IRS Notice 2025-67 and Retirement Topics: Catch-up Contributions',
             'https://www.irs.gov/retirement-plans/plan-participant-employee/retirement-topics-catch-up-contributions',
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end

    create_table :employee_retirement_elections do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.date :effective_on, null: false
      t.string :plan_name, null: false, default: "401(k)"
      t.boolean :eligible, null: false, default: true
      t.boolean :participating, null: false, default: false
      t.string :traditional_contribution_type, null: false, default: "percentage"
      t.decimal :traditional_rate, precision: 8, scale: 6, null: false, default: 0
      t.decimal :traditional_amount, precision: 14, scale: 2, null: false, default: 0
      t.string :roth_contribution_type, null: false, default: "percentage"
      t.decimal :roth_rate, precision: 8, scale: 6, null: false, default: 0
      t.decimal :roth_amount, precision: 14, scale: 2, null: false, default: 0
      t.string :eligible_compensation, null: false, default: "gross_wages"
      t.boolean :catch_up_enabled, null: false, default: false
      t.string :limit_priority, null: false, default: "proportional"
      t.decimal :plan_annual_employee_limit, precision: 14, scale: 2
      t.string :employer_match_mode, null: false, default: "none"
      t.decimal :employer_match_rate, precision: 8, scale: 6, null: false, default: 0
      t.decimal :employer_match_deferral_cap_rate, precision: 8, scale: 6
      t.decimal :employer_match_period_cap, precision: 14, scale: 2
      t.decimal :employer_match_annual_cap, precision: 14, scale: 2
      t.decimal :employer_match_ytd_before_system, precision: 14, scale: 2, null: false, default: 0
      t.string :employer_match_destination, null: false, default: "traditional"
      t.string :true_up_policy, null: false, default: "none"
      t.string :source, null: false
      t.text :reason, null: false
      t.timestamps
    end
    add_index :employee_retirement_elections, [ :employee_id, :effective_on ], unique: true,
      name: "idx_employee_retirement_elections_effective"
    add_check_constraint :employee_retirement_elections,
      "participating = FALSE OR eligible = TRUE", name: "retirement_elections_participation_eligibility"
    add_check_constraint :employee_retirement_elections,
      "traditional_contribution_type IN ('percentage', 'fixed') AND roth_contribution_type IN ('percentage', 'fixed')",
      name: "retirement_elections_contribution_types"
    add_check_constraint :employee_retirement_elections,
      "eligible_compensation IN ('gross_wages', 'gross_excluding_tips', 'base_pay')",
      name: "retirement_elections_compensation"
    add_check_constraint :employee_retirement_elections,
      "limit_priority IN ('proportional', 'traditional_first', 'roth_first')",
      name: "retirement_elections_limit_priority"
    add_check_constraint :employee_retirement_elections,
      "employer_match_mode IN ('none', 'compensation_percentage', 'employee_deferral_percentage')",
      name: "retirement_elections_match_mode"
    add_check_constraint :employee_retirement_elections,
      "employer_match_destination IN ('traditional', 'roth') AND true_up_policy IN ('none', 'year_to_date')",
      name: "retirement_elections_match_policy"
    add_check_constraint :employee_retirement_elections,
      "true_up_policy != 'year_to_date' OR employer_match_mode != 'compensation_percentage' OR eligible_compensation = 'gross_wages'",
      name: "retirement_elections_true_up_compensation"
    add_check_constraint :employee_retirement_elections,
      "traditional_rate BETWEEN 0 AND 1 AND roth_rate BETWEEN 0 AND 1 AND employer_match_rate BETWEEN 0 AND 1 AND (employer_match_deferral_cap_rate IS NULL OR employer_match_deferral_cap_rate BETWEEN 0 AND 1)",
      name: "retirement_elections_rate_ranges"
    add_check_constraint :employee_retirement_elections,
      "traditional_amount >= 0 AND roth_amount >= 0 AND employer_match_ytd_before_system >= 0 AND (plan_annual_employee_limit IS NULL OR plan_annual_employee_limit >= 0) AND (employer_match_period_cap IS NULL OR employer_match_period_cap >= 0) AND (employer_match_annual_cap IS NULL OR employer_match_annual_cap >= 0)",
      name: "retirement_elections_amount_ranges"

    add_column :payroll_items, :retirement_rule_snapshot, :jsonb, null: false, default: {}
    add_index :payroll_items, :retirement_rule_snapshot, using: :gin
  end
end
