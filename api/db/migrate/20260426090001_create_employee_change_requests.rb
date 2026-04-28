# frozen_string_literal: true

class CreateEmployeeChangeRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :employee_change_requests do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :reviewed_by, null: true, foreign_key: { to_table: :users }
      t.integer :status, null: false, default: 0
      t.jsonb :proposed_changes, null: false, default: {}
      t.jsonb :direct_changes_applied, null: false, default: {}
      t.jsonb :original_values, null: false, default: {}
      t.text :request_notes
      t.text :review_notes
      t.datetime :reviewed_at
      t.timestamps
    end

    add_index :employee_change_requests, [:company_id, :status]
    add_index :employee_change_requests, [:employee_id, :created_at]
  end
end
