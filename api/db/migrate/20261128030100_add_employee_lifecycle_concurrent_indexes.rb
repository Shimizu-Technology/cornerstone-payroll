# frozen_string_literal: true

class AddEmployeeLifecycleConcurrentIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :employees, %i[company_id id],
      where: "readiness_gate_enforced = true",
      name: "idx_employees_readiness_gate_enforced",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :employee_w4_elections, %i[id company_id],
      unique: true,
      name: "idx_employee_w4_elections_tenant_key",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :admin_overrides, %i[id company_id],
      unique: true,
      name: "idx_admin_overrides_tenant_key",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :admin_overrides,
      name: "idx_admin_overrides_tenant_key",
      algorithm: :concurrently,
      if_exists: true

    remove_index :employee_w4_elections,
      name: "idx_employee_w4_elections_tenant_key",
      algorithm: :concurrently,
      if_exists: true

    remove_index :employees,
      name: "idx_employees_readiness_gate_enforced",
      algorithm: :concurrently,
      if_exists: true
  end
end
