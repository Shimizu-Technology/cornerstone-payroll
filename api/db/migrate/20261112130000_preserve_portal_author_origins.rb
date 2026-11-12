# frozen_string_literal: true

class PreservePortalAuthorOrigins < ActiveRecord::Migration[8.1]
  def up
    add_column :client_portal_messages, :author_audience, :string, null: false, default: "unknown"
    add_column :client_portal_messages, :author_name_snapshot, :string
    add_column :client_portal_threads, :created_by_audience, :string, null: false, default: "unknown"
    add_column :client_portal_threads, :created_by_name_snapshot, :string
    execute <<~SQL
      UPDATE client_portal_messages m SET author_audience = CASE
        WHEN u.role = 4 THEN 'client' WHEN u.role IN (0, 1, 3, 5, 6) THEN 'staff' ELSE 'unknown' END,
        author_name_snapshot = u.name FROM users u WHERE u.id = m.author_id;
      UPDATE client_portal_threads t SET created_by_audience = CASE
        WHEN u.role = 4 THEN 'client' WHEN u.role IN (0, 1, 3, 5, 6) THEN 'staff' ELSE 'unknown' END,
        created_by_name_snapshot = u.name FROM users u WHERE u.id = t.created_by_id;
    SQL
    add_check_constraint :client_portal_messages, "author_audience IN ('client', 'staff', 'unknown')", name: "portal_message_author_audience"
    add_check_constraint :client_portal_threads, "created_by_audience IN ('client', 'staff', 'unknown')", name: "portal_thread_creator_audience"
  end

  def down
    remove_check_constraint :client_portal_threads, name: "portal_thread_creator_audience"
    remove_check_constraint :client_portal_messages, name: "portal_message_author_audience"
    remove_column :client_portal_threads, :created_by_name_snapshot
    remove_column :client_portal_threads, :created_by_audience
    remove_column :client_portal_messages, :author_name_snapshot
    remove_column :client_portal_messages, :author_audience
  end
end
