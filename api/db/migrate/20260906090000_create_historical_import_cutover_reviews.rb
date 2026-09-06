# frozen_string_literal: true

class CreateHistoricalImportCutoverReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :historical_import_cutover_reviews do |t|
      t.references :company, null: false, foreign_key: true
      t.references :historical_import_batch, null: false, foreign_key: true,
                                                index: { unique: true, name: "idx_historical_cutover_reviews_batch" }
      t.string :status, null: false, default: "pending"
      t.jsonb :evidence, null: false, default: {}
      t.string :evidence_digest
      t.datetime :verified_at
      t.references :verified_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.jsonb :exception_dispositions, null: false, default: {}
      t.jsonb :attestations, null: false, default: {}
      t.text :approval_notes
      t.text :approval_acknowledgement
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    add_check_constraint :historical_import_cutover_reviews,
                         "status IN ('pending', 'verified', 'approved', 'failed')",
                         name: "historical_cutover_reviews_status"
  end
end
