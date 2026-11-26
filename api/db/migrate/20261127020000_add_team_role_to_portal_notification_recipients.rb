# frozen_string_literal: true

# Adds optional Lead and Backup designations to each client's Cornerstone
# account team (portal_notification_recipients, already RLS-protected under
# RlsTables::RLS_PROTECTED_TABLES). Each company may have at most one lead and
# one backup, and only staff user rows (not extra email addresses) may hold a
# team role.
class AddTeamRoleToPortalNotificationRecipients < ActiveRecord::Migration[8.1]
  TEAM_ROLES = %w[lead backup].freeze

  def up
    execute "SET LOCAL lock_timeout = '5s'"
    add_column :portal_notification_recipients, :team_role, :string, limit: 20
    add_check_constraint :portal_notification_recipients,
      "team_role IS NULL OR team_role IN (#{TEAM_ROLES.map { |role| "'#{role}'" }.join(', ')})",
      name: "portal_notification_recipients_team_role_check"
    add_check_constraint :portal_notification_recipients,
      "team_role IS NULL OR user_id IS NOT NULL",
      name: "portal_notification_recipients_team_role_user_check"
    add_index :portal_notification_recipients, :company_id,
      unique: true, where: "team_role = 'lead'", name: "idx_portal_notification_recipients_lead"
    add_index :portal_notification_recipients, :company_id,
      unique: true, where: "team_role = 'backup'", name: "idx_portal_notification_recipients_backup"
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    remove_index :portal_notification_recipients, name: "idx_portal_notification_recipients_backup"
    remove_index :portal_notification_recipients, name: "idx_portal_notification_recipients_lead"
    remove_check_constraint :portal_notification_recipients, name: "portal_notification_recipients_team_role_user_check"
    remove_check_constraint :portal_notification_recipients, name: "portal_notification_recipients_team_role_check"
    remove_column :portal_notification_recipients, :team_role
  end
end
