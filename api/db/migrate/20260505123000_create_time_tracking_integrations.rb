# frozen_string_literal: true

class CreateTimeTrackingIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :time_tracking_sources do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.string :source_type, null: false
      t.string :base_url, null: false
      t.string :shared_secret_ciphertext
      t.boolean :active, null: false, default: true
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :time_tracking_sources, [ :company_id, :name ], unique: true
    add_index :time_tracking_sources, [ :company_id, :source_type ]

    create_table :time_tracking_employee_mappings do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.string :source_user_id, null: false
      t.string :source_email
      t.string :source_display_name
      t.timestamps
    end

    add_index :time_tracking_employee_mappings,
              [ :company_id, :time_tracking_source_id, :source_user_id ],
              unique: true,
              name: "idx_time_tracking_mappings_unique_source_user"

    create_table :time_tracking_imports do |t|
      t.references :pay_period, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true
      t.string :status, null: false, default: "previewed"
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.date :fetch_start_date, null: false
      t.date :fetch_end_date, null: false
      t.string :source_payload_hash, null: false
      t.jsonb :raw_payload, null: false, default: {}
      t.jsonb :processed_payload, null: false, default: {}
      t.jsonb :warnings, null: false, default: []
      t.datetime :applied_at
      t.references :applied_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :time_tracking_imports,
              [ :pay_period_id, :time_tracking_source_id, :start_date, :end_date, :source_payload_hash ],
              unique: true,
              name: "idx_time_tracking_imports_idempotency"
  end
end
