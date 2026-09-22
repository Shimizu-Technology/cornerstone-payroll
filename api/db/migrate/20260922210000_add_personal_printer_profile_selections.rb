# frozen_string_literal: true

class AddPersonalPrinterProfileSelections < ActiveRecord::Migration[8.0]
  def change
    change_table :printer_profiles, bulk: true do |t|
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :archived_at
      t.integer :lock_version, default: 0, null: false
    end
    remove_index :printer_profiles, name: "index_printer_profiles_on_organization_id_and_name"
    add_index :printer_profiles, [ :organization_id, :name ], unique: true,
      where: "archived_at IS NULL", name: "index_printer_profiles_on_organization_id_and_name"

    create_table :user_printer_profile_selections do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :organization, null: false, foreign_key: { on_delete: :cascade }
      t.references :printer_profile, null: false, foreign_key: { on_delete: :cascade }
      t.string :check_stock_type, null: false
      t.timestamps
    end

    add_index :user_printer_profile_selections,
      [ :organization_id, :user_id, :check_stock_type ],
      unique: true,
      name: "idx_user_printer_selections_on_org_user_stock"
    add_check_constraint :user_printer_profile_selections,
      "check_stock_type IN ('bottom_check', 'top_check', 'first_hawaiian_4up')",
      name: "user_printer_selections_stock_type_check"

    change_table :check_print_runs, bulk: true do |t|
      t.references :printer_profile, foreign_key: { on_delete: :nullify }
      t.jsonb :calibration_snapshot, default: {}, null: false
    end
  end
end
