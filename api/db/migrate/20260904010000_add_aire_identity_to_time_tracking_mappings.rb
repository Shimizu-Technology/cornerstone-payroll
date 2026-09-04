# frozen_string_literal: true

class AddAireIdentityToTimeTrackingMappings < ActiveRecord::Migration[8.1]
  def change
    add_column :time_tracking_employee_mappings, :source_user_uuid, :uuid
    add_index :time_tracking_employee_mappings,
              [ :company_id, :time_tracking_source_id, :source_user_uuid ],
              unique: true,
              where: "source_user_uuid IS NOT NULL",
              name: "idx_time_tracking_mappings_unique_source_uuid"
    add_index :time_tracking_employee_mappings,
              [ :company_id, :time_tracking_source_id, :employee_id ],
              unique: true,
              where: "source_user_uuid IS NOT NULL",
              name: "idx_time_tracking_mappings_unique_employee"

    add_column :time_tracking_imports, :reconciliation_note, :text
    add_column :time_tracking_imports, :reconciled_at, :datetime
    add_reference :time_tracking_imports, :reconciled_by, foreign_key: { to_table: :users }
  end
end
