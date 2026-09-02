# frozen_string_literal: true

class AddSourceProcessingEventTimeToTimeTrackingImports < ActiveRecord::Migration[8.1]
  def change
    add_column :time_tracking_imports, :source_processing_event_occurred_at, :datetime
  end
end
