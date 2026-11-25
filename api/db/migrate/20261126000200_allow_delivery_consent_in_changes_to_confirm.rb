# frozen_string_literal: true

class AllowDeliveryConsentInChangesToConfirm < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    remove_check_constraint :employee_contact_changes_to_confirm, name: "employee_contact_changes_kind_check"
    add_check_constraint :employee_contact_changes_to_confirm,
      "change_kind IN ('contact', 'address', 'delivery_consent')",
      name: "employee_contact_changes_kind_check",
      validate: false
  end

  def down
    # Narrowing the check constraint on rollback would reject recorded
    # delivery_consent audit entries; recovery means rolling forward.
    raise ActiveRecord::IrreversibleMigration,
      "Cannot narrow employee_contact_changes_kind_check without rejecting delivery_consent audit entries"
  end
end
