# frozen_string_literal: true

class BackfillNonEmployeeCheckPeriodType < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE non_employee_checks
      SET payment_period_type = 'pay_period'
      WHERE pay_period_id IS NOT NULL
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE non_employee_checks
      SET payment_period_type = 'none'
      WHERE pay_period_id IS NOT NULL
    SQL
  end
end
