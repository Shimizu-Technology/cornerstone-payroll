# frozen_string_literal: true

# A reviewer's "1099s ready" sign-off for one client and tax year, bound to a
# fingerprint of everything that prints on the 1099-NECs. It counts only
# while that fingerprint matches the current inputs.
class CreateForm1099FilingReadinesses < ActiveRecord::Migration[8.1]
  def change
    create_table :form_1099_filing_readinesses do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.integer :tax_year, null: false
      t.string :ready_fingerprint
      t.datetime :marked_ready_at
      t.references :marked_ready_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :marked_ready_by_name
      t.text :notes
      t.integer :payee_count, null: false, default: 0
      t.decimal :total_compensation, precision: 14, scale: 2, null: false, default: 0
      t.jsonb :attestation_history, null: false, default: []

      t.timestamps
    end

    add_index :form_1099_filing_readinesses, %i[company_id tax_year], unique: true,
              name: "idx_form_1099_filing_readinesses_unique_year"
    add_check_constraint :form_1099_filing_readinesses, "tax_year BETWEEN 2000 AND 2200",
                         name: "form_1099_filing_readinesses_year_check"
    add_check_constraint :form_1099_filing_readinesses,
                         "(ready_fingerprint IS NULL) = (marked_ready_at IS NULL)",
                         name: "form_1099_filing_readinesses_mark_check"
  end
end
