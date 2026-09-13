# frozen_string_literal: true

class CreateAirePayrollCalendarSync < ActiveRecord::Migration[8.1]
  def change
    add_column :company_pay_schedules, :payroll_cutoff_days_before, :integer, null: false, default: 7
    add_column :company_pay_schedules, :payroll_cutoff_at_minutes, :integer, null: false, default: 1_020
    add_check_constraint :company_pay_schedules,
                         "payroll_cutoff_days_before BETWEEN 0 AND 31",
                         name: "company_pay_schedules_cutoff_days_check"
    add_check_constraint :company_pay_schedules,
                         "payroll_cutoff_at_minutes BETWEEN 0 AND 1439",
                         name: "company_pay_schedules_cutoff_time_check"

    create_table :aire_payroll_calendar_periods do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :time_tracking_source, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: false, foreign_key: { on_delete: :restrict }
      t.uuid :external_pay_period_id, null: false
      t.timestamps
    end

    add_index :aire_payroll_calendar_periods,
              [ :time_tracking_source_id, :pay_period_id ],
              unique: true,
              name: "idx_aire_calendar_periods_source_pay_period"
    add_index :aire_payroll_calendar_periods,
              :external_pay_period_id,
              unique: true,
              name: "idx_aire_calendar_periods_external_id"
    create_table :aire_payroll_calendar_publications do |t|
      t.references :aire_payroll_calendar_period, null: false,
                   foreign_key: { on_delete: :restrict }, index: { name: "idx_aire_calendar_publications_period" }
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :schedule_version, null: false
      t.uuid :publication_id, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :payload_checksum, null: false
      t.string :delivery_status, null: false, default: "pending"
      t.integer :delivery_attempts, null: false, default: 0
      t.datetime :delivery_enqueued_until
      t.datetime :last_delivery_attempt_at
      t.datetime :next_delivery_attempt_at
      t.datetime :delivered_at
      t.integer :last_response_status
      t.text :last_error
      t.jsonb :source_state, null: false, default: {}
      t.timestamps
    end

    add_index :aire_payroll_calendar_publications,
              [ :aire_payroll_calendar_period_id, :schedule_version ],
              unique: true,
              name: "idx_aire_calendar_publications_version"
    add_index :aire_payroll_calendar_publications,
              :publication_id,
              unique: true,
              name: "idx_aire_calendar_publications_publication"
    add_index :aire_payroll_calendar_publications,
              [ :delivery_status, :next_delivery_attempt_at, :delivery_enqueued_until ],
              name: "idx_aire_calendar_publications_due"
    add_check_constraint :aire_payroll_calendar_publications,
                         "schedule_version > 0",
                         name: "aire_calendar_publications_version_check"
    add_check_constraint :aire_payroll_calendar_publications,
                         "delivery_status IN ('pending', 'failed', 'delivered')",
                         name: "aire_calendar_publications_status_check"
    add_check_constraint :aire_payroll_calendar_publications,
                         "delivery_attempts >= 0",
                         name: "aire_calendar_publications_attempts_check"

    create_table :aire_payroll_events do |t|
      t.references :aire_payroll_calendar_period, null: false,
                   foreign_key: { on_delete: :restrict }, index: { name: "idx_aire_payroll_events_period" }
      t.references :aire_payroll_calendar_publication, null: false,
                   foreign_key: { on_delete: :restrict }, index: { name: "idx_aire_payroll_events_publication" }
      t.uuid :event_id, null: false
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :payload_checksum, null: false
      t.string :verification_status, null: false, default: "pending"
      t.integer :verification_attempts, null: false, default: 0
      t.datetime :verification_enqueued_until
      t.datetime :last_verification_attempt_at
      t.datetime :next_verification_attempt_at
      t.datetime :verified_at
      t.text :last_error
      t.string :payroll_batch_id, null: false
      t.string :payroll_batch_checksum, null: false
      t.jsonb :verified_batch_summary, null: false, default: {}
      t.timestamps
    end

    add_index :aire_payroll_events, :event_id, unique: true,
              name: "idx_aire_payroll_events_event_id"
    add_index :aire_payroll_events, :payroll_batch_id, unique: true,
              name: "idx_aire_payroll_events_batch_id"
    add_index :aire_payroll_events,
              [ :verification_status, :next_verification_attempt_at, :verification_enqueued_until ],
              name: "idx_aire_payroll_events_due"
    add_check_constraint :aire_payroll_events,
                         "event_type = 'payroll_batch.finalized'",
                         name: "aire_payroll_events_type_check"
    add_check_constraint :aire_payroll_events,
                         "verification_status IN ('pending', 'failed', 'rejected', 'verified')",
                         name: "aire_payroll_events_status_check"
    add_check_constraint :aire_payroll_events,
                         "verification_attempts >= 0",
                         name: "aire_payroll_events_attempts_check"
  end
end
