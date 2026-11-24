# frozen_string_literal: true

class AddContactDetailsTrackingToEmployees < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :email_verified_at, :datetime
    add_column :employees, :phone_confirmed_by_employee_at, :datetime
    add_column :employees, :contact_source, :string

    add_check_constraint :employees,
                         "contact_source IS NULL OR contact_source IN ('client', 'staff', 'employee', 'import')",
                         name: "employees_contact_source_check",
                         validate: false
  end
end
