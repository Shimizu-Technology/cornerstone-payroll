# frozen_string_literal: true

require_relative "support/login_link_decision_function"

class CreatePayrollEmployeeLoginLinkDecision < ActiveRecord::Migration[8.1]
  def up
    execute LoginLinkDecisionFunction.schema_sql
  end

  def down
    execute "DROP FUNCTION IF EXISTS #{LoginLinkDecisionFunction::SIGNATURE}"
  end
end
