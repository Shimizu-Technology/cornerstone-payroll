# frozen_string_literal: true

class ValidateAdminOverrides < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    validate_foreign_key :admin_overrides, :companies
    validate_foreign_key :admin_overrides, :users, column: :actor_id
    validate_foreign_key :admin_overrides, :users, column: :real_user_id
    validate_check_constraint :admin_overrides, name: "admin_overrides_reason_length"
  end

  def down
    # Validation leaves the constraints in place.
  end
end
