# frozen_string_literal: true

# Client portal logins get one of two access levels: manager (full access,
# what every existing client login has today) or viewer (read-only). The
# constant default fills existing rows without rewriting the table
# (PostgreSQL 11+), and the short lock timeout makes the deploy fail fast
# instead of queueing behind a long-running query on users.
class AddClientAccessLevelToUsers < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    add_column :users, :client_access_level, :string, default: "manager", null: false
    add_check_constraint :users, "client_access_level IN ('manager', 'viewer')", name: "users_client_access_level_check"
  end

  # Rolling back drops every viewer assignment; migrating again restores all
  # client logins as managers, so re-mark viewers after a rollback.
  def down
    execute "SET LOCAL lock_timeout = '5s'"
    remove_check_constraint :users, name: "users_client_access_level_check"
    remove_column :users, :client_access_level
  end
end
