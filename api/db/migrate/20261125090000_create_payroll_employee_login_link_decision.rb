# frozen_string_literal: true

require_relative "support/login_link_decision_function"

class CreatePayrollEmployeeLoginLinkDecision < ActiveRecord::Migration[8.1]
  def up
    execute LoginLinkDecisionFunction.schema_sql(current_schema)
  end

  def down
    execute "DROP FUNCTION IF EXISTS #{LoginLinkDecisionFunction.qualified_signature(current_schema)}"
  end

  private

  def current_schema
    select_value("SELECT current_schema()")
  end
end
