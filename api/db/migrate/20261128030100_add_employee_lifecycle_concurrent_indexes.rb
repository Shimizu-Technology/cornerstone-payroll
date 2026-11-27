# frozen_string_literal: true

class AddEmployeeLifecycleConcurrentIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEXES = [
    [ :employees, %i[company_id id], { where: "readiness_gate_enforced = true", name: "idx_employees_readiness_gate_enforced" } ],
    [ :employee_w4_elections, %i[id company_id], { unique: true, name: "idx_employee_w4_elections_tenant_key" } ],
    [ :admin_overrides, %i[id company_id], { unique: true, name: "idx_admin_overrides_tenant_key" } ]
  ].freeze

  def up
    INDEXES.each do |table, columns, options|
      ensure_concurrent_index(table, columns, **options)
    end
  end

  def down
    INDEXES.reverse_each do |table, _columns, options|
      remove_index table, name: options.fetch(:name), algorithm: :concurrently, if_exists: true
    end
  end

  private

  def ensure_concurrent_index(table, columns, name:, **options)
    # A failed concurrent build leaves an INVALID index behind; drop it
    # concurrently so a rerun builds a valid index instead of skipping it.
    if invalid_index?(name)
      remove_index table, name: name, algorithm: :concurrently, if_exists: true
    end

    add_index table, columns, **options, name: name, algorithm: :concurrently, if_not_exists: true
  end

  def invalid_index?(index_name)
    select_value(<<~SQL).present?
      SELECT 1
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema()
        AND c.relname = #{connection.quote(index_name)}
        AND NOT i.indisvalid
    SQL
  end
end
