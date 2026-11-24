# frozen_string_literal: true

require_relative "support/login_eligible_link_function"

# M4-2 review: why and when a login was deactivated, so only a login closed
# with its last employee link can reactivate itself on rehire, and so
# sessions from before the closure stay refused afterwards. Additive only.
class AddEmployeeLoginClosureAndEligibleLinkCheck < ActiveRecord::Migration[8.1]
  REASONS = %w[last_employee_link_closed pending_sign_up_closed deactivated].freeze

  def up
    change_table :users, bulk: true do |t|
      t.datetime :deactivated_at
      t.string :deactivation_reason
    end
    add_check_constraint :users, "deactivation_reason IS NULL OR deactivation_reason IN (#{REASONS.map { |r| "'#{r}'" }.join(', ')})",
      name: "users_deactivation_reason_check"
    execute LoginEligibleLinkFunction.schema_sql(current_schema)
  end

  def down
    execute "DROP FUNCTION IF EXISTS #{LoginEligibleLinkFunction.qualified_signature(current_schema)}"
    remove_check_constraint :users, name: "users_deactivation_reason_check"
    change_table :users, bulk: true do |t|
      t.remove :deactivated_at, :deactivation_reason
    end
  end

  private

  def current_schema
    select_value("SELECT current_schema()")
  end
end
