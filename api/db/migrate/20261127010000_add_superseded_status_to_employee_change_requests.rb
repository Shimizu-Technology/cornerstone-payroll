# frozen_string_literal: true

# Adds the superseded status (4): an employee's pending address request that
# a direct staff or Client manager edit replaced. The constraint names every
# status the model knows, so a stray value can't be written. Rolling back
# turns superseded rows into cancelled ones, the closest older status, so the
# older code can still read them.
class AddSupersededStatusToEmployeeChangeRequests < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    add_check_constraint :employee_change_requests, "status IN (0, 1, 2, 3, 4)",
      name: "employee_change_requests_status_check", validate: false
    validate_check_constraint :employee_change_requests, name: "employee_change_requests_status_check"
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    execute "UPDATE employee_change_requests SET status = 3 WHERE status = 4"
    remove_check_constraint :employee_change_requests, name: "employee_change_requests_status_check"
  end
end
