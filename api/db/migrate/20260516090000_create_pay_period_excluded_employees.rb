# frozen_string_literal: true

class CreatePayPeriodExcludedEmployees < ActiveRecord::Migration[7.1]
  def change
    create_table :pay_period_excluded_employees do |t|
      t.references :pay_period, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :excluded_by, foreign_key: { to_table: :users }
      t.string :reason

      t.timestamps
    end

    add_index :pay_period_excluded_employees,
      [ :pay_period_id, :employee_id ],
      unique: true,
      name: "idx_pay_period_exclusions_on_period_employee"
  end
end
