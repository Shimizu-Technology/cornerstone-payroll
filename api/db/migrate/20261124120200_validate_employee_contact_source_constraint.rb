# frozen_string_literal: true

class ValidateEmployeeContactSourceConstraint < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :employees, name: "employees_contact_source_check"
  end

  def down
    # Validated check constraints remain valid on down; rollback of the earlier
    # migration removes the constraint itself.
  end
end
