class AddEmployeeIntakeExceptions < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :employee_intake_expires_at, :datetime
    add_column :companies, :employee_intake_reason, :text
    add_reference :companies, :employee_intake_enabled_by, foreign_key: { to_table: :users }
    add_column :employees, :intake_exception, :jsonb, null: false, default: {}
    add_column :employees, :intake_payroll_eligible_from, :date
    add_column :employees, :intake_payroll_confirmed_at, :datetime
  end
end
