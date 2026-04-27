# frozen_string_literal: true

class CreateForm500Filings < ActiveRecord::Migration[8.0]
  def change
    create_table :form500_filings do |t|
      t.references :company, null: false, foreign_key: true
      t.references :pay_period, null: false, foreign_key: true, index: { unique: true }
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }
      t.jsonb :fields, null: false, default: {}

      t.timestamps
    end
  end
end
