# frozen_string_literal: true

class CreateHistoricalClientBootstrapDispatches < ActiveRecord::Migration[8.0]
  def change
    create_table :historical_client_bootstrap_dispatches do |t|
      t.references :historical_client_bootstrap, null: false, foreign_key: true, index: false
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :attempt_token, null: false
      t.integer :dispatch_attempts, null: false, default: 0
      t.datetime :enqueued_at
      t.datetime :completed_at
      t.text :last_error
      t.timestamps
    end

    add_index :historical_client_bootstrap_dispatches,
              [ :historical_client_bootstrap_id, :attempt_token ],
              unique: true,
              name: "idx_historical_bootstrap_dispatch_attempt"
    add_index :historical_client_bootstrap_dispatches,
              [ :completed_at, :enqueued_at ],
              name: "idx_historical_bootstrap_dispatch_due"
  end
end
