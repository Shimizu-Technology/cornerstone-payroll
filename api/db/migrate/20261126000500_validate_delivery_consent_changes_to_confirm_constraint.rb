# frozen_string_literal: true

class ValidateDeliveryConsentChangesToConfirmConstraint < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    validate_check_constraint :employee_contact_changes_to_confirm, name: "employee_contact_changes_kind_check"
  end

  def down
    # Validated check constraints remain valid on down; rollback is not needed.
  end
end
