# frozen_string_literal: true

class AddInvoiceScheduling < ActiveRecord::Migration[8.0]
  def change
    create_table :invoice_recurrences do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :source_invoice, null: false, foreign_key: { to_table: :invoices }
      t.references :created_by, foreign_key: { to_table: :users }
      t.date :start_on, null: false
      t.date :next_on, null: false
      t.date :ends_on
      t.string :interval_unit, null: false
      t.integer :interval_count, default: 1, null: false
      t.integer :occurrence_index, default: 0, null: false
      t.integer :due_after_days, default: 30, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_check_constraint :invoice_recurrences, "interval_unit IN ('week', 'month')", name: "check_invoice_recurrence_unit"
    add_check_constraint :invoice_recurrences, "interval_count > 0 AND due_after_days >= 0 AND occurrence_index >= 0", name: "check_invoice_recurrence_numbers"
    add_index :invoice_recurrences, [ :active, :next_on ]

    add_reference :invoices, :invoice_recurrence, foreign_key: true
    add_column :invoices, :recurrence_on, :date
    add_index :invoices, [ :invoice_recurrence_id, :recurrence_on ], unique: true,
              where: "invoice_recurrence_id IS NOT NULL", name: "index_invoices_on_recurrence_occurrence"

    create_table :invoice_send_schedules do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.jsonb :recipients, default: [], null: false
      t.datetime :send_at, null: false
      t.string :status, default: "pending", null: false
      t.integer :attempts, default: 0, null: false
      t.string :provider_reference
      t.text :last_error
      t.datetime :claimed_at
      t.datetime :sent_at
      t.timestamps
    end
    add_check_constraint :invoice_send_schedules, "status IN ('pending', 'sending', 'sent', 'failed', 'cancelled')", name: "check_invoice_send_schedule_status"
    add_index :invoice_send_schedules, [ :status, :send_at ]
  end
end
