# frozen_string_literal: true

class IndexEmployeesOnLowerEmail < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_employees_on_lower_email"

  def up
    # A failed concurrent build leaves an INVALID index behind; drop it
    # concurrently so a rerun builds a valid index instead of skipping it.
    if invalid_index?
      remove_index :employees, name: INDEX_NAME, algorithm: :concurrently
    end

    add_index :employees,
              "LOWER(TRIM(email))",
              name: INDEX_NAME,
              where: "email IS NOT NULL",
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :employees,
                 name: INDEX_NAME,
                 algorithm: :concurrently,
                 if_exists: true
  end

  private

  def invalid_index?
    select_value(<<~SQL).present?
      SELECT 1
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema()
        AND c.relname = #{connection.quote(INDEX_NAME)}
        AND NOT i.indisvalid
    SQL
  end
end
