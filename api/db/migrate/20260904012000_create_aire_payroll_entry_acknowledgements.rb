# frozen_string_literal: true

class CreateAirePayrollEntryAcknowledgements < ActiveRecord::Migration[8.1]
  def change
    create_table :aire_payroll_entry_acknowledgements do |t|
      t.references :time_tracking_import, null: false, foreign_key: true
      t.references :payroll_item, null: false, foreign_key: true
      t.references :check_event, foreign_key: true
      t.string :source_event_key, null: false
      t.string :event_id, null: false
      t.string :source_time_entry_id, null: false
      t.string :source_user_id, null: false
      t.uuid :source_user_uuid
      t.string :status, null: false
      t.datetime :occurred_at, null: false
      t.string :payment_method
      t.string :payment_reference
      t.datetime :enqueued_at
      t.datetime :delivered_at
      t.text :last_error

      t.timestamps
    end

    add_index :aire_payroll_entry_acknowledgements, :source_event_key, unique: true, name: "idx_aire_entry_ack_unique_source_event"
    add_index :aire_payroll_entry_acknowledgements, :event_id, unique: true
    add_index :aire_payroll_entry_acknowledgements,
              [ :delivered_at, :enqueued_at ],
              name: "idx_aire_entry_ack_dispatch"
    add_check_constraint :aire_payroll_entry_acknowledgements,
                         "status IN ('imported', 'committed', 'payment_prepared', 'payment_issued', 'payment_failed', 'payment_voided')",
                         name: "aire_payroll_entry_ack_status_check"
  end
end
