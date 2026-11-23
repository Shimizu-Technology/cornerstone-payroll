# frozen_string_literal: true

require_relative "support/m3_7_child_companies"

class ExpandPayrollChildCompanies < ActiveRecord::Migration[8.1]
  include M3_7ChildCompanies
  disable_ddl_transaction!

  def up
    with_short_ddl_transaction { execute FILL_FUNCTION }

    CHILDREN.each do |table, (key, parent)|
      # Publish the nullable column and its fallback together. Release the
      # table's exclusive lock before touching the next table.
      with_short_ddl_transaction do
        add_column table, :company_id, :bigint, if_not_exists: true
        execute M3_7ChildCompanies.trigger_sql(table, key, parent)
      end
    end
  end

  def down
    CHILDREN.each_key do |table|
      with_short_ddl_transaction do
        execute "DROP TRIGGER IF EXISTS #{M3_7ChildCompanies.trigger_name(table)} ON #{table}"
        remove_column table, :company_id, if_exists: true
      end
    end
    with_short_ddl_transaction { execute "DROP FUNCTION IF EXISTS fill_child_company_from_parent()" }
  end
end
