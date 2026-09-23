# frozen_string_literal: true

class AddPrinterProfileLineage < ActiveRecord::Migration[8.0]
  def change
    add_reference :printer_profiles, :source_profile,
      foreign_key: { to_table: :printer_profiles, on_delete: :nullify }
    add_column :printer_profiles, :revision_number, :integer, default: 1, null: false
    add_index :printer_profiles, [ :source_profile_id, :revision_number ],
      unique: true,
      where: "source_profile_id IS NOT NULL",
      name: "idx_printer_profiles_unique_source_revision"
    add_check_constraint :printer_profiles, "revision_number >= 1",
      name: "printer_profiles_revision_number_positive"
  end
end
