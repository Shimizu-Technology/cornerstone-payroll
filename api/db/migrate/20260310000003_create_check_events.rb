# frozen_string_literal: true

class CreateCheckEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :check_events do |t|
      t.references :payroll_item, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      # Event types: printed | voided | reprinted | batch_downloaded | alignment_test
      t.string :event_type, null: false
      t.string :check_number
      t.string :reason
      t.string :ip_address
      t.timestamps
    end

    add_index :check_events, [ :payroll_item_id, :event_type ]
    add_index :check_events, :check_number
    add_index :check_events, :event_type
  end
end
