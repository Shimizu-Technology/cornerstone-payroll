# frozen_string_literal: true

class AddFinalizedBatchProvenanceToTimeTrackingImports < ActiveRecord::Migration[8.1]
  def change
    change_table :time_tracking_imports, bulk: true do |t|
      t.string :external_batch_id
      t.string :external_batch_checksum
      t.string :contract_version
      t.datetime :source_cutoff_at
      t.text :negative_adjustment_acknowledgement
    end

    add_index :time_tracking_imports,
              [ :time_tracking_source_id, :external_batch_id ],
              unique: true,
              where: "external_batch_id IS NOT NULL",
              name: "idx_time_tracking_imports_unique_external_batch"
    add_check_constraint :time_tracking_imports,
                         <<~SQL.squish,
                           (external_batch_id IS NULL AND external_batch_checksum IS NULL AND contract_version IS NULL AND source_cutoff_at IS NULL)
                           OR
                           (external_batch_id IS NOT NULL AND external_batch_checksum IS NOT NULL AND contract_version IS NOT NULL AND source_cutoff_at IS NOT NULL)
                         SQL
                         name: "time_tracking_imports_batch_provenance_complete"
  end
end
