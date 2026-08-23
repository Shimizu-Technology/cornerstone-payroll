# frozen_string_literal: true

class HardenEmployeeChangeRequests < ActiveRecord::Migration[8.0]
  def up
    duplicate_employee_ids = select_values(<<~SQL.squish)
      SELECT employee_id
      FROM employee_change_requests
      WHERE status = 0
      GROUP BY employee_id
      HAVING COUNT(*) > 1
      ORDER BY employee_id
    SQL
    if duplicate_employee_ids.any?
      raise ActiveRecord::MigrationError,
        "Resolve duplicate pending employee change requests before migrating. Employee IDs: #{duplicate_employee_ids.join(', ')}"
    end

    add_column :employee_change_requests, :request_kind, :string, null: false, default: "update"
    add_column :employee_change_requests, :sensitive_payload_encrypted, :text
    add_column :employees, :portal_pending_approval, :boolean, null: false, default: false

    add_index :employee_change_requests,
      :employee_id,
      unique: true,
      where: "status = 0",
      name: "idx_employee_change_requests_one_pending"

    add_check_constraint :employee_change_requests,
      "request_kind IN ('create', 'update')",
      name: "employee_change_requests_kind_check"
    add_check_constraint :employees,
      "portal_pending_approval = FALSE OR status = 'inactive'",
      name: "employees_portal_pending_inactive_check"
  end

  def down
    remove_check_constraint :employees, name: "employees_portal_pending_inactive_check"
    remove_check_constraint :employee_change_requests, name: "employee_change_requests_kind_check"
    remove_index :employee_change_requests, name: "idx_employee_change_requests_one_pending"
    remove_column :employees, :portal_pending_approval
    remove_column :employee_change_requests, :sensitive_payload_encrypted
    remove_column :employee_change_requests, :request_kind
  end
end
