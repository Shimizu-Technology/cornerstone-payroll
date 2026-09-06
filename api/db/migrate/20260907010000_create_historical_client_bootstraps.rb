# frozen_string_literal: true

class CreateHistoricalClientBootstraps < ActiveRecord::Migration[8.0]
  def change
    add_column :employees, :configuration_source, :string
    add_column :employees, :configuration_review_status, :string, null: false, default: "complete"
    add_column :employees, :configuration_review_items, :jsonb, null: false, default: []

    add_check_constraint :employees,
                         "configuration_review_status IN ('complete', 'needs_review')",
                         name: "employees_configuration_review_status_check"
    add_check_constraint :employees,
                         "configuration_source IS NULL OR configuration_source IN ('quickbooks_history')",
                         name: "employees_configuration_source_check"
    add_check_constraint :employees,
                         "jsonb_typeof(configuration_review_items) = 'array'",
                         name: "employees_configuration_review_items_array"

    create_table :historical_client_bootstraps do |t|
      t.references :company, null: false, foreign_key: true
      t.references :historical_import_batch, null: false, foreign_key: true, index: { unique: true }
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :applied_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :status, null: false, default: "previewed"
      t.string :plan_digest, null: false
      t.jsonb :preview_summary, null: false, default: {}
      t.jsonb :warnings, null: false, default: []
      t.jsonb :validation_errors, null: false, default: []
      t.jsonb :review_items, null: false, default: []
      t.datetime :apply_started_at
      t.text :apply_error
      t.datetime :applied_at
      t.timestamps
    end

    add_index :historical_client_bootstraps, [ :company_id, :status ]
    add_foreign_key :historical_client_bootstraps,
                    :historical_import_batches,
                    column: [ :historical_import_batch_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_historical_client_bootstraps_batch_tenant"
    add_check_constraint :historical_client_bootstraps,
                         "status IN ('previewed', 'pending', 'applied', 'failed')",
                         name: "historical_client_bootstraps_status_check"
    add_check_constraint :historical_client_bootstraps,
                         "jsonb_typeof(preview_summary) = 'object'",
                         name: "historical_client_bootstraps_summary_object"
    add_check_constraint :historical_client_bootstraps,
                         "jsonb_typeof(warnings) = 'array' AND jsonb_typeof(validation_errors) = 'array' AND jsonb_typeof(review_items) = 'array'",
                         name: "historical_client_bootstraps_arrays"
  end
end
