# frozen_string_literal: true

class AddEmployeeLifecycleAndTimekeepingFoundation < ActiveRecord::Migration[8.0]
  def change
    create_table :employee_work_profiles do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :confirmed_by, foreign_key: { to_table: :users }
      t.date :effective_on, null: false
      t.date :ends_on
      t.string :pay_basis, null: false
      t.string :overtime_status, null: false, default: "needs_review"
      t.string :exemption_category
      t.text :exemption_reason
      t.decimal :standard_weekly_hours, precision: 6, scale: 2
      t.jsonb :daily_schedule, null: false, default: {}
      t.string :timekeeping_mode, null: false, default: "manual"
      t.string :source, null: false, default: "operator_confirmed"
      t.string :confirmation_status, null: false, default: "needs_confirmation"
      t.datetime :confirmed_at
      t.text :notes
      t.timestamps
    end
    add_index :employee_work_profiles, [ :employee_id, :effective_on ], unique: true,
              name: "idx_employee_work_profiles_effective"
    add_index :employee_work_profiles, :employee_id, unique: true,
              where: "ends_on IS NULL", name: "idx_employee_work_profiles_one_current"
    add_check_constraint :employee_work_profiles, "ends_on IS NULL OR ends_on >= effective_on",
                         name: "employee_work_profiles_dates_check"
    add_check_constraint :employee_work_profiles, "pay_basis IN ('hourly', 'salary', 'contractor')",
                         name: "employee_work_profiles_pay_basis_check"
    add_check_constraint :employee_work_profiles, "overtime_status IN ('exempt', 'nonexempt', 'needs_review')",
                         name: "employee_work_profiles_overtime_status_check"
    add_check_constraint :employee_work_profiles, "timekeeping_mode IN ('imported', 'manual', 'schedule_with_exceptions')",
                         name: "employee_work_profiles_mode_check"
    add_check_constraint :employee_work_profiles, "source IN ('operator_confirmed', 'production_migration', 'imported', 'legacy_system_default')",
                         name: "employee_work_profiles_source_check"
    add_check_constraint :employee_work_profiles, "confirmation_status IN ('confirmed', 'needs_confirmation')",
                         name: "employee_work_profiles_confirmation_check"
    add_check_constraint :employee_work_profiles,
                         "standard_weekly_hours IS NULL OR (standard_weekly_hours > 0 AND standard_weekly_hours <= 168)",
                         name: "employee_work_profiles_weekly_hours_check"

    create_table :employee_status_events do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :event_type, null: false
      t.string :previous_status, null: false
      t.string :resulting_status, null: false
      t.date :effective_date, null: false
      t.date :last_worked_on
      t.string :reason_category
      t.text :internal_notes
      t.string :source, null: false, default: "operator"
      t.timestamps
    end
    add_index :employee_status_events, [ :employee_id, :effective_date, :id ],
              name: "idx_employee_status_events_timeline"
    add_check_constraint :employee_status_events, "event_type IN ('terminated', 'reactivated')",
                         name: "employee_status_events_type_check"
    add_check_constraint :employee_status_events, "previous_status IN ('active', 'inactive', 'terminated')",
                         name: "employee_status_events_previous_status_check"
    add_check_constraint :employee_status_events, "resulting_status IN ('active', 'inactive', 'terminated')",
                         name: "employee_status_events_resulting_status_check"
    add_check_constraint :employee_status_events, "last_worked_on IS NULL OR last_worked_on <= effective_date",
                         name: "employee_status_events_last_worked_check"
    add_check_constraint :employee_status_events, "source IN ('operator', 'production_migration')",
                         name: "employee_status_events_source_check"

    create_table :daily_time_records do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :employee_work_profile, foreign_key: true
      t.references :supersedes, foreign_key: { to_table: :daily_time_records }
      t.date :work_date, null: false
      t.date :workweek_started_on, null: false
      t.decimal :scheduled_hours, precision: 6, scale: 2, null: false, default: 0
      t.decimal :actual_worked_hours, precision: 6, scale: 2
      t.decimal :pto_hours, precision: 6, scale: 2, null: false, default: 0
      t.decimal :holiday_hours, precision: 6, scale: 2, null: false, default: 0
      t.string :source, null: false
      t.string :ledger_key, null: false, default: "authoritative"
      t.integer :revision, null: false, default: 1
      t.text :exception_reason
      t.text :override_reason
      t.datetime :superseded_at
      t.timestamps
    end
    add_index :daily_time_records, [ :employee_id, :work_date, :ledger_key ], unique: true,
              where: "superseded_at IS NULL", name: "idx_daily_time_records_current_day"
    add_index :daily_time_records, [ :employee_id, :workweek_started_on, :ledger_key ],
              name: "idx_daily_time_records_workweek"
    add_check_constraint :daily_time_records, "source IN ('schedule', 'import', 'manual', 'correction_reference', 'production_backfill')",
                         name: "daily_time_records_source_check"
    add_check_constraint :daily_time_records, "ledger_key IN ('authoritative', 'parallel', 'test', 'historical')",
                         name: "daily_time_records_ledger_check"
    add_check_constraint :daily_time_records,
                         "scheduled_hours >= 0 AND scheduled_hours <= 24 AND (actual_worked_hours IS NULL OR (actual_worked_hours >= 0 AND actual_worked_hours <= 24)) AND pto_hours >= 0 AND holiday_hours >= 0",
                         name: "daily_time_records_hours_check"

    create_table :payroll_time_allocations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :payroll_item, null: false, foreign_key: true
      t.references :daily_time_record, null: false, foreign_key: true
      t.date :work_date, null: false
      t.decimal :scheduled_hours, precision: 6, scale: 2, null: false, default: 0
      t.decimal :regular_hours, precision: 6, scale: 2, null: false, default: 0
      t.decimal :overtime_hours, precision: 6, scale: 2, null: false, default: 0
      t.decimal :pto_hours, precision: 6, scale: 2, null: false, default: 0
      t.decimal :holiday_hours, precision: 6, scale: 2, null: false, default: 0
      t.string :source, null: false
      t.string :ledger_key, null: false, default: "authoritative"
      t.timestamps
    end
    add_index :payroll_time_allocations, [ :payroll_item_id, :daily_time_record_id ], unique: true,
              name: "idx_payroll_time_allocations_unique"
    add_index :payroll_time_allocations, [ :employee_id, :work_date, :ledger_key ],
              name: "idx_payroll_time_allocations_employee_day"
    add_check_constraint :payroll_time_allocations, "source IN ('schedule', 'import', 'manual', 'correction_reference', 'production_backfill')",
                         name: "payroll_time_allocations_source_check"
    add_check_constraint :payroll_time_allocations, "ledger_key IN ('authoritative', 'parallel', 'test', 'historical')",
                         name: "payroll_time_allocations_ledger_check"
    add_check_constraint :payroll_time_allocations,
                         "scheduled_hours >= 0 AND regular_hours >= 0 AND overtime_hours >= 0 AND pto_hours >= 0 AND holiday_hours >= 0",
                         name: "payroll_time_allocations_hours_check"

    add_column :payroll_items, :scheduled_hours, :decimal, precision: 8, scale: 2, null: false, default: 0
    add_column :payroll_items, :timekeeping_source, :string
    add_column :payroll_items, :timekeeping_context_snapshot, :jsonb, null: false, default: {}
    add_check_constraint :payroll_items,
                         "timekeeping_source IS NULL OR timekeeping_source IN ('schedule', 'import', 'manual', 'correction_reference', 'production_backfill')",
                         name: "payroll_items_timekeeping_source_check"
  end
end
