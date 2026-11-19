# frozen_string_literal: true

# A reviewer's explicit "reviewed" decision on a year-end judgment warning.
# The digest binds it to the affected employees and amounts it was made on.
class CreateYearEndAcknowledgements < ActiveRecord::Migration[8.1]
  def change
    create_table :year_end_acknowledgements do |t|
      t.references :company, null: false, foreign_key: true
      t.integer :tax_year, null: false
      t.string :warning_code, null: false
      t.string :warning_digest, null: false
      t.text :note, null: false
      t.references :acknowledged_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :acknowledged_by_name, null: false
      t.string :acknowledged_by_email, null: false
      t.string :acknowledged_by_role, null: false
      t.datetime :acknowledged_at, null: false

      t.timestamps
    end

    add_index :year_end_acknowledgements, %i[company_id tax_year warning_code],
              unique: true, name: "idx_year_end_acknowledgements_unique_warning"
    add_check_constraint :year_end_acknowledgements, "tax_year BETWEEN 2000 AND 2200",
                         name: "year_end_acknowledgements_year_check"
  end
end
