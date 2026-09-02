# frozen_string_literal: true

class CreateAirePayrollAcknowledgements < ActiveRecord::Migration[8.1]
  def change
    create_table :aire_payroll_acknowledgements do |t|
      t.references :time_tracking_import, null: false, foreign_key: true
      t.string :event_id, null: false
      t.string :status, null: false
      t.datetime :occurred_at, null: false
      t.datetime :enqueued_at
      t.datetime :delivered_at
      t.text :last_error

      t.timestamps
    end

    add_index :aire_payroll_acknowledgements, :event_id, unique: true
    add_index :aire_payroll_acknowledgements,
              [ :delivered_at, :enqueued_at ],
              name: "idx_aire_payroll_acknowledgements_dispatch"
    add_check_constraint :aire_payroll_acknowledgements,
                         "status IN ('imported', 'committed', 'payment_issued', 'payment_failed')",
                         name: "aire_payroll_acknowledgements_status_check"
  end
end
