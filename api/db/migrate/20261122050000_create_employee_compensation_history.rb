# frozen_string_literal: true

# Effective-dated pay rates (M3-4). employees.pay_rate and the
# employee_wage_rates rate columns become caches of the version in effect
# today; these tables hold the history readers resolve against.
class CreateEmployeeCompensationHistory < ActiveRecord::Migration[8.1]
  def up
    # History belongs to its employee and wage-rate rows. Application code
    # never deletes those (rates are ended, employees terminated), and
    # CompensationWriteLint rejects raw deletes, so the cascade only serves
    # whole-record removal such as test fixture cleanup.
    create_table :employee_compensation_changes do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :employee, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.decimal :pay_rate, precision: 18, scale: 6, null: false
      t.string :employment_type, null: false
      t.string :salary_type
      t.string :pay_frequency
      t.string :contractor_pay_type
      t.date :effective_on, null: false
      t.date :ends_on
      t.text :reason, null: false
      t.string :source, null: false
      t.boolean :historical_correction, null: false, default: false
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :employee_compensation_changes, %i[employee_id effective_on], unique: true,
      name: "idx_employee_compensation_changes_employee_effective"
    add_index :employee_compensation_changes, :employee_id, unique: true, where: "ends_on IS NULL",
      name: "idx_employee_compensation_changes_one_current"
    add_index :employee_compensation_changes, %i[company_id effective_on],
      name: "idx_employee_compensation_changes_company_effective"
    add_check_constraint :employee_compensation_changes, "ends_on IS NULL OR ends_on >= effective_on",
      name: "employee_compensation_changes_ends_after_start"
    add_check_constraint :employee_compensation_changes, "pay_rate >= 0",
      name: "employee_compensation_changes_pay_rate_nonnegative"

    create_table :employee_wage_rate_versions do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :employee, null: false, foreign_key: { on_delete: :cascade }
      t.references :employee_wage_rate, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :label, null: false
      t.decimal :rate, precision: 12, scale: 6
      t.boolean :is_primary, null: false, default: false
      t.boolean :active, null: false, default: true
      t.date :effective_on, null: false
      t.date :ends_on
      t.text :reason, null: false
      t.string :source, null: false
      t.boolean :historical_correction, null: false, default: false
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :employee_wage_rate_versions, %i[employee_wage_rate_id effective_on], unique: true,
      name: "idx_employee_wage_rate_versions_rate_effective"
    add_index :employee_wage_rate_versions, :employee_wage_rate_id, unique: true, where: "ends_on IS NULL",
      name: "idx_employee_wage_rate_versions_one_current"
    add_index :employee_wage_rate_versions, %i[company_id effective_on],
      name: "idx_employee_wage_rate_versions_company_effective"
    add_check_constraint :employee_wage_rate_versions, "ends_on IS NULL OR ends_on >= effective_on",
      name: "employee_wage_rate_versions_ends_after_start"
    add_check_constraint :employee_wage_rate_versions, "rate IS NULL OR rate >= 0",
      name: "employee_wage_rate_versions_rate_nonnegative"

    backfill_baselines!
  end

  def down
    drop_table :employee_wage_rate_versions
    drop_table :employee_compensation_changes
  end

  private

  # One open baseline per employee and wage rate, holding today's values and
  # dated early enough to cover every pay period the employee can appear in:
  # LEAST(hire date, the company's earliest pay period start, created date).
  # Every existing reader therefore resolves exactly the value it reads now.
  def backfill_baselines!
    execute <<~SQL
      WITH baselines AS (
        SELECT e.id AS employee_id,
               LEAST(
                 COALESCE(e.hire_date, e.created_at::date),
                 COALESCE((SELECT MIN(pp.start_date) FROM pay_periods pp WHERE pp.company_id = e.company_id), e.created_at::date),
                 e.created_at::date
               ) AS effective_on
        FROM employees e
      )
      INSERT INTO employee_compensation_changes
        (company_id, employee_id, pay_rate, employment_type, salary_type, pay_frequency, contractor_pay_type,
         effective_on, ends_on, reason, source, historical_correction, created_by_id, created_at, updated_at)
      SELECT e.company_id, e.id, e.pay_rate, e.employment_type, e.salary_type, e.pay_frequency, e.contractor_pay_type,
             b.effective_on, NULL, 'Baseline recorded from the existing employee setup', 'backfill', FALSE, NULL, NOW(), NOW()
      FROM employees e
      JOIN baselines b ON b.employee_id = e.id
      WHERE NOT EXISTS (SELECT 1 FROM employee_compensation_changes c WHERE c.employee_id = e.id)
    SQL

    execute <<~SQL
      INSERT INTO employee_wage_rate_versions
        (company_id, employee_id, employee_wage_rate_id, label, rate, is_primary, active,
         effective_on, ends_on, reason, source, historical_correction, created_by_id, created_at, updated_at)
      SELECT e.company_id, e.id, r.id, r.label, r.rate, r.is_primary, r.active,
             c.effective_on, NULL, 'Baseline recorded from the existing wage-rate setup', 'backfill', FALSE, NULL, NOW(), NOW()
      FROM employee_wage_rates r
      JOIN employees e ON e.id = r.employee_id
      JOIN employee_compensation_changes c ON c.employee_id = e.id AND c.source = 'backfill'
      WHERE NOT EXISTS (SELECT 1 FROM employee_wage_rate_versions v WHERE v.employee_wage_rate_id = r.id)
    SQL
  end
end
