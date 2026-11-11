# frozen_string_literal: true

class AddPortalThreadRetryKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :client_portal_threads, :idempotency_key, :string
    add_column :client_portal_threads, :creation_payload, :jsonb, null: false, default: {}
    add_index :client_portal_threads, [ :company_id, :created_by_id, :idempotency_key ], unique: true,
      where: "idempotency_key IS NOT NULL", name: "idx_portal_threads_author_retry"
  end
end
