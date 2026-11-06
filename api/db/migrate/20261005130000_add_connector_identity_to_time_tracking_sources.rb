# frozen_string_literal: true

class AddConnectorIdentityToTimeTrackingSources < ActiveRecord::Migration[8.1]
  def up
    add_column :time_tracking_sources, :remote_source_identifier, :string
    add_column :time_tracking_sources, :authorization_origin, :string
    add_column :time_tracking_sources, :source_policy_constraints, :jsonb, default: {}, null: false
    execute "UPDATE time_tracking_sources SET remote_source_identifier = source_type WHERE source_type != 'custom'"
  end

  def down
    remove_column :time_tracking_sources, :authorization_origin
    remove_column :time_tracking_sources, :source_policy_constraints
    remove_column :time_tracking_sources, :remote_source_identifier
  end
end
