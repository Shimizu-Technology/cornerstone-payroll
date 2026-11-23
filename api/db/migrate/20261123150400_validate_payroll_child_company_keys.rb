# frozen_string_literal: true

require_relative "support/m3_7_child_companies"

class ValidatePayrollChildCompanyKeys < ActiveRecord::Migration[8.1]
  include M3_7ChildCompanies
  disable_ddl_transaction!

  def up
    CHILDREN.each_key do |table|
      with_short_ddl_transaction do
        validate_foreign_key table, name: M3_7ChildCompanies.foreign_key_name(table)
      end
    end
  end

  def down
    # PostgreSQL cannot mark a validated FK NOT VALID without dropping it.
    # The preceding migration owns removal of these constraints on rollback.
  end
end
