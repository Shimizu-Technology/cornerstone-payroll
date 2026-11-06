# frozen_string_literal: true

class AddConnectionIdentityToTimeTrackingSources < ActiveRecord::Migration[8.1]
  def change
    add_column :time_tracking_sources, :connection_uuid, :uuid, null: false, default: -> { "gen_random_uuid()" }
    add_column :time_tracking_sources, :expected_source_instance_id, :string
    add_column :time_tracking_sources, :source_protocol, :string
    add_column :time_tracking_sources, :source_protocol_version, :string
    add_column :time_tracking_sources, :source_capabilities, :jsonb, null: false, default: []
    add_column :time_tracking_sources, :identity_verified_at, :datetime

    add_index :time_tracking_sources, :connection_uuid, unique: true
    add_check_constraint :time_tracking_sources,
                         "jsonb_typeof(source_capabilities) = 'array'",
                         name: "time_tracking_sources_capabilities_array"
    add_check_constraint :time_tracking_sources, <<~SQL.squish,
      (
        expected_source_instance_id IS NULL AND source_protocol IS NULL AND
        source_protocol_version IS NULL AND identity_verified_at IS NULL
      ) OR (
        expected_source_instance_id IS NOT NULL AND source_protocol IS NOT NULL AND
        source_protocol_version IS NOT NULL AND identity_verified_at IS NOT NULL
      )
    SQL
                         name: "time_tracking_sources_identity_complete"
  end
end
