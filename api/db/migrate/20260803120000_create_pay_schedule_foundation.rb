# frozen_string_literal: true

class CreatePayScheduleFoundation < ActiveRecord::Migration[8.0]
  def change
    create_table :company_pay_schedules do |t|
      t.references :company, null: false, foreign_key: true
      t.string :frequency, null: false
      t.string :period_rule, null: false, default: "manual"
      t.integer :period_start_weekday
      t.string :pay_date_rule, null: false, default: "manual"
      t.integer :pay_date_offset_days
      t.string :timezone, null: false, default: "Pacific/Guam"
      t.string :source, null: false, default: "legacy_system_default"
      t.string :confirmation_status, null: false, default: "needs_confirmation"
      t.references :confirmed_by, foreign_key: { to_table: :users }
      t.datetime :confirmed_at
      t.date :effective_on, null: false
      t.date :ends_on
      t.text :notes
      t.timestamps
    end

    add_index :company_pay_schedules,
              [ :company_id, :effective_on ],
              unique: true,
              name: "idx_company_pay_schedules_effective"
    add_index :company_pay_schedules,
              :company_id,
              unique: true,
              where: "ends_on IS NULL",
              name: "idx_company_pay_schedules_one_current"
    add_check_constraint :company_pay_schedules,
                         "frequency IN ('weekly', 'biweekly', 'semimonthly', 'monthly')",
                         name: "company_pay_schedules_frequency_check"
    add_check_constraint :company_pay_schedules,
                         "period_rule IN ('manual', 'weekly', 'biweekly', 'semimonthly')",
                         name: "company_pay_schedules_period_rule_check"
    add_check_constraint :company_pay_schedules,
                         "pay_date_rule IN ('manual', 'days_after_period_end')",
                         name: "company_pay_schedules_pay_date_rule_check"
    add_check_constraint :company_pay_schedules,
                         "source IN ('operator_confirmed', 'production_inferred', 'legacy_system_default')",
                         name: "company_pay_schedules_source_check"
    add_check_constraint :company_pay_schedules,
                         "confirmation_status IN ('confirmed', 'needs_confirmation')",
                         name: "company_pay_schedules_confirmation_check"
    add_check_constraint :company_pay_schedules,
                         "period_start_weekday IS NULL OR period_start_weekday BETWEEN 0 AND 6",
                         name: "company_pay_schedules_weekday_check"
    add_check_constraint :company_pay_schedules,
                         "ends_on IS NULL OR ends_on >= effective_on",
                         name: "company_pay_schedules_dates_check"

    create_table :company_workweeks do |t|
      t.references :company, null: false, foreign_key: true
      t.integer :starts_on_weekday, null: false, default: 0
      t.integer :starts_at_minutes, null: false, default: 0
      t.string :timezone, null: false, default: "Pacific/Guam"
      t.string :source, null: false, default: "legacy_system_default"
      t.string :confirmation_status, null: false, default: "needs_confirmation"
      t.references :confirmed_by, foreign_key: { to_table: :users }
      t.datetime :confirmed_at
      t.date :effective_on, null: false
      t.date :ends_on
      t.text :notes
      t.timestamps
    end

    add_index :company_workweeks,
              [ :company_id, :effective_on ],
              unique: true,
              name: "idx_company_workweeks_effective"
    add_index :company_workweeks,
              :company_id,
              unique: true,
              where: "ends_on IS NULL",
              name: "idx_company_workweeks_one_current"
    add_check_constraint :company_workweeks,
                         "starts_on_weekday BETWEEN 0 AND 6",
                         name: "company_workweeks_weekday_check"
    add_check_constraint :company_workweeks,
                         "starts_at_minutes BETWEEN 0 AND 1439",
                         name: "company_workweeks_time_check"
    add_check_constraint :company_workweeks,
                         "source IN ('operator_confirmed', 'production_inferred', 'legacy_system_default')",
                         name: "company_workweeks_source_check"
    add_check_constraint :company_workweeks,
                         "confirmation_status IN ('confirmed', 'needs_confirmation')",
                         name: "company_workweeks_confirmation_check"
    add_check_constraint :company_workweeks,
                         "ends_on IS NULL OR ends_on >= effective_on",
                         name: "company_workweeks_dates_check"

    change_table :pay_periods, bulk: true do |t|
      t.string :run_purpose, null: false, default: "regular"
      t.boolean :includes_base_salary, null: false, default: true
      t.string :run_purpose_source, null: false, default: "legacy_system_default"
      t.references :company_pay_schedule, foreign_key: true
      t.references :company_workweek, foreign_key: true
    end

    add_index :pay_periods, [ :company_id, :run_purpose ], name: "idx_pay_periods_company_purpose"
    add_check_constraint :pay_periods,
                         "run_purpose IN ('regular', 'off_cycle_tips', 'bonus', 'commission', 'correction', 'final', 'adjustment')",
                         name: "pay_periods_run_purpose_check"
    add_check_constraint :pay_periods,
                         "run_purpose_source IN ('operator_selected', 'system_correction', 'production_migration', 'legacy_system_default')",
                         name: "pay_periods_run_purpose_source_check"
    add_check_constraint :pay_periods,
                         "run_purpose <> 'off_cycle_tips' OR includes_base_salary = FALSE",
                         name: "pay_periods_off_cycle_tips_salary_check"
  end
end
