# frozen_string_literal: true

class CreateUnifiedTransmittalBuilder < ActiveRecord::Migration[8.0]
  def change
    add_reference :general_transmittals,
      :pay_period,
      foreign_key: true,
      index: { unique: true, where: "pay_period_id IS NOT NULL" }
    add_column :general_transmittals, :source_kind, :string, null: false, default: "standalone"

    add_column :general_transmittal_items, :included, :boolean, null: false, default: true
    add_column :general_transmittal_items, :source_key, :string
    add_column :general_transmittal_items, :metadata, :jsonb, null: false, default: {}
    add_index :general_transmittal_items,
      [ :general_transmittal_id, :source_key ],
      unique: true,
      where: "source_key IS NOT NULL",
      name: "idx_transmittal_items_on_transmittal_source_key"

    create_table :general_transmittal_artifacts do |t|
      t.references :general_transmittal, null: false, foreign_key: true, index: false
      t.references :company, null: false, foreign_key: true
      t.references :created_by, null: true, foreign_key: { to_table: :users }
      t.integer :version_number, null: false
      t.string :storage_key, null: false
      t.string :filename, null: false
      t.string :content_type, null: false, default: "application/pdf"
      t.bigint :byte_size, null: false
      t.string :sha256, null: false
      t.string :template_version, null: false
      t.jsonb :snapshot, null: false, default: {}
      t.timestamps
    end

    add_index :general_transmittal_artifacts,
      [ :general_transmittal_id, :version_number ],
      unique: true,
      name: "idx_transmittal_artifacts_on_transmittal_version"
    add_index :general_transmittal_artifacts, :storage_key, unique: true
    add_check_constraint :general_transmittal_artifacts,
      "version_number > 0",
      name: "general_transmittal_artifacts_version_positive"
    add_check_constraint :general_transmittal_artifacts,
      "byte_size > 0",
      name: "general_transmittal_artifacts_byte_size_positive"
    add_check_constraint :general_transmittal_artifacts,
      "char_length(sha256) = 64",
      name: "general_transmittal_artifacts_sha256_length"
    add_check_constraint :general_transmittals,
      "source_kind IN ('standalone', 'pay_period')",
      name: "general_transmittals_source_kind_check"
  end
end
