# frozen_string_literal: true

class AllowDeliveryConsentInChangesToConfirm < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :employee_contact_changes_to_confirm, name: "employee_contact_changes_kind_check"
    add_check_constraint :employee_contact_changes_to_confirm,
      "change_kind IN ('contact', 'address', 'delivery_consent')",
      name: "employee_contact_changes_kind_check"
  end

  def down
    remove_check_constraint :employee_contact_changes_to_confirm, name: "employee_contact_changes_kind_check"
    add_check_constraint :employee_contact_changes_to_confirm,
      "change_kind IN ('contact', 'address')",
      name: "employee_contact_changes_kind_check"
  end
end
