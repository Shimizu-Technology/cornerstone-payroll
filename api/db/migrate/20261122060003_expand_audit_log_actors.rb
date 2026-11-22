# frozen_string_literal: true

class ExpandAuditLogActors < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "idx_audit_logs_company_actor_type_created_at"

  class HistoricalAuditLog < ActiveRecord::Base
    self.table_name = "audit_logs"
  end

  def up
    %i[actor_type actor_id].each do |column|
      transaction do
        execute "SET LOCAL lock_timeout = '5s'"
        add_column :audit_logs, column, :string, if_not_exists: true
      end
    end
    replace_rollout_audit_function(typed: true)

    HistoricalAuditLog.reset_column_information
    # Limit this pass to the existing inventory. Old instances can keep
    # writing NULL actor_type until the expand deploy finishes.
    last_id = HistoricalAuditLog.maximum(:id)
    HistoricalAuditLog.where(actor_type: nil, id: ..last_id).in_batches(of: 1_000) do |batch|
      batch.update_all(<<~SQL.squish)
        actor_type = CASE
          WHEN action = 'aire_payroll_calendar#cutoff_changed' AND metadata ->> 'requested_via' = 'aire_services'
            THEN 'source_system'
          WHEN user_id IS NOT NULL THEN
            CASE COALESCE(actor_role, (SELECT CASE role WHEN 4 THEN 'client' WHEN 2 THEN 'employee' END
                FROM users WHERE users.id = audit_logs.user_id))
              WHEN 'client' THEN 'client_user'
              WHEN 'employee' THEN 'employee'
              ELSE 'staff_user'
            END
          WHEN actor_role = 'operator' THEN 'operator'
          WHEN action IN ('worker_statements#listed', 'worker_statement#viewed', 'worker_statement#pdf_downloaded')
            THEN 'source_worker'
          WHEN action IN ('aire_payroll_event#received', 'aire_payroll_calendar#published') THEN 'source_system'
          ELSE 'system_job'
        END,
        actor_id = CASE
          WHEN action = 'aire_payroll_calendar#cutoff_changed' AND metadata ->> 'requested_via' = 'aire_services' THEN NULL
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
    transaction do
      execute "SET LOCAL lock_timeout = '5s'"
      replace_rollout_audit_function(typed: false)
      remove_column :audit_logs, :actor_id, if_exists: true
      remove_column :audit_logs, :actor_type, if_exists: true
    end
  end

  private

  def replace_rollout_audit_function(typed:)
    execute <<~SQL
      CREATE OR REPLACE FUNCTION audit_time_tracking_lock_rollout() RETURNS trigger AS $$
      BEGIN
        IF NEW.source_type = 'aire_services' THEN
          INSERT INTO audit_logs (action, actor_name, actor_role#{", actor_type" if typed}, company_id, organization_id,
            record_type, record_id, event_category, metadata, created_at)
          SELECT 'time_tracking_source#lock_rollout_configured', 'Approved lock rollout', 'system'#{", 'system_job'" if typed},
            NEW.company_id, companies.organization_id, 'TimeTrackingSource', NEW.id, 'integration',
            jsonb_build_object('cutoff_enforcement_starts_on', NEW.cutoff_enforcement_starts_on,
              'reason', 'Approved rollout: periods before October 16, 2026 lock only on explicit operator request'),
            CURRENT_TIMESTAMP
          FROM companies WHERE companies.id = NEW.company_id;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end
end
