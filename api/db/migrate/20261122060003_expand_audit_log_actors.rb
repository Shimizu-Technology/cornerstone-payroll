# frozen_string_literal: true

class ExpandAuditLogActors < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "idx_audit_logs_company_actor_type_created_at"

  class HistoricalAuditLog < ActiveRecord::Base
    self.table_name = "audit_logs"
  end

  def up
    add_column :audit_logs, :actor_type, :string, if_not_exists: true
    add_column :audit_logs, :actor_id, :string, if_not_exists: true

    HistoricalAuditLog.reset_column_information
    # Limit this pass to the existing inventory. Old instances can keep
    # writing NULL actor_type until the expand deploy finishes.
    last_id = HistoricalAuditLog.maximum(:id)
    HistoricalAuditLog.where(actor_type: nil, id: ..last_id).in_batches(of: 1_000) do |batch|
      batch.update_all(<<~SQL.squish)
        actor_type = CASE
          WHEN user_id IS NOT NULL THEN
            CASE WHEN COALESCE(actor_role = 'client', (SELECT role = 4 FROM users WHERE users.id = audit_logs.user_id))
              THEN 'client_user' ELSE 'staff_user' END
          WHEN actor_role = 'operator' THEN 'operator'
          WHEN action IN ('worker_statements#listed', 'worker_statement#viewed', 'worker_statement#pdf_downloaded')
            THEN 'source_worker'
          WHEN action = 'aire_payroll_event#received' THEN 'source_system'
          ELSE 'system_job'
        END,
        actor_id = CASE
          WHEN user_id IS NOT NULL THEN user_id::text
          WHEN action IN ('worker_statements#listed', 'worker_statement#viewed', 'worker_statement#pdf_downloaded')
            THEN metadata ->> 'source_user_uuid'
        END
      SQL
    end if last_id

    # A failed concurrent build can leave an index with the right name but
    # indisvalid=false. Repair that before retrying the build.
    if index_exists?(:audit_logs, name: INDEX_NAME, valid: false)
      remove_index :audit_logs, name: INDEX_NAME, algorithm: :concurrently
    end
    add_index :audit_logs, %i[company_id actor_type created_at], name: INDEX_NAME,
      algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :audit_logs, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    remove_column :audit_logs, :actor_id, if_exists: true
    remove_column :audit_logs, :actor_type, if_exists: true
  end
end
