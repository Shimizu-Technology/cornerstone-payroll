# frozen_string_literal: true

class CreateW2FilingReadinesses < ActiveRecord::Migration[8.1]
  def change
    create_table :w2_filing_readinesses do |t|
      t.references :company, null: false, foreign_key: true
      t.integer :year, null: false
      t.datetime :preflight_run_at
      t.integer :blocking_count, null: false, default: 0
      t.integer :warning_count, null: false, default: 0
      t.jsonb :findings, null: false, default: []
      t.string :status, null: false, default: "draft"
      t.datetime :marked_ready_at
      t.references :marked_ready_by, foreign_key: { to_table: :users }
      t.text :notes

      t.timestamps
    end

    add_index :w2_filing_readinesses, [:company_id, :year], unique: true
  end
end
