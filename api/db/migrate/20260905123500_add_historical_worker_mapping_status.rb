# frozen_string_literal: true

class AddHistoricalWorkerMappingStatus < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:historical_workers, :mapping_status)
      add_column :historical_workers, :mapping_status, :string, null: false, default: "needs_review"
    end
    unless check_constraint_exists?(:historical_workers, name: "historical_workers_mapping_status")
      add_check_constraint :historical_workers,
                           "mapping_status IN ('needs_review', 'exact_match', 'manual_match', 'archive_only')",
                           name: "historical_workers_mapping_status"
    end
  end

  def down
    remove_check_constraint :historical_workers, name: "historical_workers_mapping_status" if check_constraint_exists?(:historical_workers, name: "historical_workers_mapping_status")
    remove_column :historical_workers, :mapping_status if column_exists?(:historical_workers, :mapping_status)
  end
end
