# frozen_string_literal: true

class AddCustomEntriesToTransmittals < ActiveRecord::Migration[7.1]
  def change
    add_column :transmittals, :custom_entries, :jsonb, default: []
  end
end
