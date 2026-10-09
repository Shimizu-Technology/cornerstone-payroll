class AddEmployeeIntakeExceptions < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :employee_w4_elections,
      "source IN ('staff', 'client_approved', 'employee_creation', 'legacy_profile', 'quickbooks_history')",
      name: "employee_w4_elections_source_check"
    add_check_constraint :employee_w4_elections,
      "source IN ('staff', 'client_approved', 'employee_creation', 'legacy_profile', 'quickbooks_history', 'default_withholding')",
      name: "employee_w4_elections_source_check"
    add_column :companies, :employee_intake_expires_at, :datetime
    add_column :companies, :employee_intake_reason, :text
    add_reference :companies, :employee_intake_enabled_by, foreign_key: { to_table: :users }
    add_column :employees, :intake_exception, :jsonb, null: false, default: {}
    add_column :employees, :intake_payroll_eligible_from, :date
    add_column :employees, :intake_payroll_confirmed_at, :datetime
  end
end
