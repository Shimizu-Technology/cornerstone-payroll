# frozen_string_literal: true

class AllowEmployeeDeactivationEvents < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :employee_status_events, name: "employee_status_events_type_check"
    add_check_constraint :employee_status_events, "event_type IN ('terminated', 'reactivated', 'deactivated')",
                         name: "employee_status_events_type_check"
  end

  def down
    remove_check_constraint :employee_status_events, name: "employee_status_events_type_check"
    add_check_constraint :employee_status_events, "event_type IN ('terminated', 'reactivated')",
                         name: "employee_status_events_type_check"
  end
end
