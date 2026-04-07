# frozen_string_literal: true

class EnhancePayrollReminderLogs < ActiveRecord::Migration[8.0]
  def change
    change_column_null :payroll_reminder_logs, :pay_period_id, true
    add_column :payroll_reminder_logs, :expected_pay_date, :date

    remove_index :payroll_reminder_logs, name: "idx_reminder_logs_unique_per_type"

    add_index :payroll_reminder_logs,
              [:company_id, :pay_period_id, :reminder_type],
              unique: true,
              where: "pay_period_id IS NOT NULL",
              name: "idx_reminder_logs_period_unique"

    add_index :payroll_reminder_logs,
              [:company_id, :reminder_type, :expected_pay_date],
              unique: true,
              where: "pay_period_id IS NULL AND expected_pay_date IS NOT NULL",
              name: "idx_reminder_logs_create_unique"
  end
end
