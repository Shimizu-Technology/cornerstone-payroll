# frozen_string_literal: true

class AddSourceProcessingStatusToTimeTrackingImports < ActiveRecord::Migration[8.1]
  def change
    add_column :time_tracking_imports, :source_processing_status, :string
    add_column :time_tracking_imports, :source_processing_synced_at, :datetime
    add_column :time_tracking_imports, :source_processing_sync_error, :text
    add_index :time_tracking_imports, :source_processing_status
  end
end
