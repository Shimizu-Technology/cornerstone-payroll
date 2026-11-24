# frozen_string_literal: true

class AddContactDetailsTrackingToEmployees < ActiveRecord::Migration[8.1]
  CONSTRAINT_NAME = "employees_contact_source_check"

  def up
    execute "SET LOCAL lock_timeout = '5s'"

    add_column :employees, :email_verified_at, :datetime, if_not_exists: true
    add_column :employees, :phone_confirmed_by_employee_at, :datetime, if_not_exists: true
    add_column :employees, :contact_source, :string, if_not_exists: true

    unless check_constraints(:employees).any? { |c| c.name == CONSTRAINT_NAME }
      add_check_constraint :employees,
                           "contact_source IS NULL OR contact_source IN ('client', 'staff', 'employee', 'import')",
                           name: CONSTRAINT_NAME,
                           validate: false
    end
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"

    remove_check_constraint :employees, name: CONSTRAINT_NAME, if_exists: true
    remove_column :employees, :contact_source, if_exists: true
    remove_column :employees, :phone_confirmed_by_employee_at, if_exists: true
    remove_column :employees, :email_verified_at, if_exists: true
  end
end
