# frozen_string_literal: true

class AddTimecardApplyStateAndEmployeeDefaultEarnings < ActiveRecord::Migration[7.1]
  def change
    add_column :employees, :default_custom_earnings, :jsonb, default: [], null: false

    add_reference :timecards, :applied_employee, foreign_key: { to_table: :employees }
    add_reference :timecards, :applied_payroll_item, foreign_key: { to_table: :payroll_items }
    add_column :timecards, :applied_to_payroll_at, :datetime
  end
end
