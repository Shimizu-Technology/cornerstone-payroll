# frozen_string_literal: true

class IndexEmployeesOnLowerEmail < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_employees_on_lower_email"

  def up
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
end
