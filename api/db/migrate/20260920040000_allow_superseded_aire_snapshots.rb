# frozen_string_literal: true

class AllowSupersededAireSnapshots < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_time_tracking_imports_idempotency"
  COLUMNS = %i[pay_period_id time_tracking_source_id start_date end_date source_payload_hash].freeze

  def up
    remove_index :time_tracking_imports, name: INDEX_NAME
    add_index :time_tracking_imports, COLUMNS, unique: true, name: INDEX_NAME,
              where: "status <> 'superseded'"
  end

  def down
    remove_index :time_tracking_imports, name: INDEX_NAME
    add_index :time_tracking_imports, COLUMNS, unique: true, name: INDEX_NAME
  end
end
