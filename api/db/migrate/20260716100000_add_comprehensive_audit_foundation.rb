# frozen_string_literal: true

class AddComprehensiveAuditFoundation < ActiveRecord::Migration[8.1]
  def up
    add_reference :audit_logs, :organization, foreign_key: true
    add_column :audit_logs, :actor_name, :string
    add_column :audit_logs, :actor_email, :string
    add_column :audit_logs, :actor_role, :string
    add_column :audit_logs, :subject_name, :string
    add_column :audit_logs, :request_id, :string
    add_column :audit_logs, :event_category, :string, null: false, default: "activity"

    add_index :audit_logs, [ :organization_id, :created_at, :id ], name: "idx_audit_logs_org_history"
    add_index :audit_logs, :request_id
    add_index :audit_logs, [ :organization_id, :record_type, :record_id ], name: "idx_audit_logs_org_subject"

    add_column :users, :last_active_at, :datetime
    add_column :users, :last_session_id_digest, :string

    execute <<~SQL.squish
      UPDATE audit_logs
      SET organization_id = companies.organization_id
      FROM companies
      WHERE audit_logs.organization_id IS NULL
        AND audit_logs.company_id = companies.id
    SQL

    execute <<~SQL.squish
      UPDATE audit_logs
      SET organization_id = users.organization_id
      FROM users
      WHERE audit_logs.organization_id IS NULL
        AND audit_logs.user_id = users.id
    SQL

    execute <<~SQL.squish
      UPDATE audit_logs
      SET actor_name = users.name,
          actor_email = users.email,
          actor_role = CASE users.role
            WHEN 0 THEN 'admin'
            WHEN 1 THEN 'manager'
            WHEN 2 THEN 'employee'
            WHEN 3 THEN 'accountant'
            WHEN 4 THEN 'client'
            WHEN 5 THEN 'super_admin'
            WHEN 6 THEN 'org_admin'
            ELSE 'unknown'
          END
      FROM users
      WHERE audit_logs.user_id = users.id
    SQL
  end

  def down
    remove_column :users, :last_session_id_digest
    remove_column :users, :last_active_at

    remove_index :audit_logs, name: "idx_audit_logs_org_subject"
    remove_index :audit_logs, :request_id
    remove_index :audit_logs, name: "idx_audit_logs_org_history"
    remove_column :audit_logs, :event_category
    remove_column :audit_logs, :request_id
    remove_column :audit_logs, :subject_name
    remove_column :audit_logs, :actor_role
    remove_column :audit_logs, :actor_email
    remove_column :audit_logs, :actor_name
    remove_reference :audit_logs, :organization, foreign_key: true
  end
end
