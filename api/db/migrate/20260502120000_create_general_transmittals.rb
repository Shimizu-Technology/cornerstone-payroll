# frozen_string_literal: true

class CreateGeneralTransmittals < ActiveRecord::Migration[8.1]
  def change
    create_table :general_transmittals do |t|
      t.references :company, null: false, foreign_key: true
      t.string :title, null: false
      t.date :transmittal_date, null: false
      t.string :preparer_name
      t.string :recipient_name
      t.jsonb :notes, null: false, default: []
      t.string :status, null: false, default: "draft"
      t.datetime :generated_at
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :general_transmittals, [ :company_id, :transmittal_date ],
      name: "idx_general_transmittals_on_company_date"
    add_check_constraint :general_transmittals,
      "status IN ('draft', 'generated')",
      name: "general_transmittals_status_check"

    create_table :general_transmittal_items do |t|
      t.references :general_transmittal, null: false, foreign_key: { on_delete: :cascade }, index: { name: "idx_general_transmittal_items_on_transmittal" }
      t.string :source_type
      t.bigint :source_id
      t.string :item_type, null: false, default: "manual"
      t.string :title, null: false
      t.string :payable_to
      t.string :check_number
      t.decimal :amount, precision: 10, scale: 2
      t.jsonb :details, null: false, default: []
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :general_transmittal_items,
      [ :general_transmittal_id, :position ],
      name: "idx_general_transmittal_items_on_transmittal_position"
    add_index :general_transmittal_items,
      [ :source_type, :source_id ],
      name: "idx_general_transmittal_items_on_source"
    add_check_constraint :general_transmittal_items,
      "amount IS NULL OR amount >= 0",
      name: "general_transmittal_items_amount_nonnegative"
  end
end
