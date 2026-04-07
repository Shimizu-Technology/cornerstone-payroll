# frozen_string_literal: true

class CreatePayrollReminderLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :payroll_reminder_logs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :pay_period, null: false, foreign_key: true
      t.string :reminder_type, null: false
      t.jsonb :recipients_snapshot, default: [], null: false
      t.datetime :sent_at, null: false
      t.timestamps
    end

    add_index :payroll_reminder_logs,
              [:company_id, :pay_period_id, :reminder_type],
              unique: true,
              name: "idx_reminder_logs_unique_per_type"
  end
end
