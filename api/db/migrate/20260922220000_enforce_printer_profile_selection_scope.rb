# frozen_string_literal: true

class EnforcePrinterProfileSelectionScope < ActiveRecord::Migration[8.0]
  def up
    add_index :printer_profiles,
      [ :id, :organization_id, :check_stock_type ],
      unique: true,
      name: "idx_printer_profiles_identity_scope"

    add_foreign_key :user_printer_profile_selections,
      :printer_profiles,
      column: [ :printer_profile_id, :organization_id, :check_stock_type ],
      primary_key: [ :id, :organization_id, :check_stock_type ],
      name: "fk_user_printer_selections_profile_scope",
      on_delete: :cascade
  end

  def down
    remove_foreign_key :user_printer_profile_selections,
      name: "fk_user_printer_selections_profile_scope"
    remove_index :printer_profiles, name: "idx_printer_profiles_identity_scope"
  end
end
