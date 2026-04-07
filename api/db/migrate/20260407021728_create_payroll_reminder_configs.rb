# frozen_string_literal: true

class CreatePayrollReminderConfigs < ActiveRecord::Migration[8.0]
  def change
    create_table :payroll_reminder_configs do |t|
      t.references :company, null: false, foreign_key: true, index: { unique: true }
      t.boolean :enabled, default: false, null: false
      t.jsonb :recipients, default: [], null: false
      t.integer :days_before_due, default: 3, null: false
      t.boolean :send_overdue_alerts, default: true, null: false
      t.timestamps
    end
  end
end
