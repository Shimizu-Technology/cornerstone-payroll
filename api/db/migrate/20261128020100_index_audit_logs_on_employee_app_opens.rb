# frozen_string_literal: true

# The employee app status report and panel read each login's latest recorded
# app open (the audited employee_portal/context#show). This partial index lets
# that be one backward index step per login instead of a scan of every open.
# Built concurrently: audit_logs is large and written on every request.
class IndexAuditLogsOnEmployeeAppOpens < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX = "idx_audit_logs_employee_app_opens"

  def up
    with_session_lock_timeout do
      # A concurrent build can leave an invalid index after a lock timeout.
      remove_index :audit_logs, name: INDEX, algorithm: :concurrently if index_exists?(:audit_logs, name: INDEX, valid: false)
      add_index :audit_logs, %i[company_id user_id created_at], order: { created_at: :desc },
        where: "action = 'employee_portal/context#show'", name: INDEX, algorithm: :concurrently, if_not_exists: true
    end
  end

  def down
    with_session_lock_timeout do
      remove_index :audit_logs, name: INDEX, algorithm: :concurrently, if_exists: true
    end
  end

  private

  def with_session_lock_timeout
    previous_timeout = select_value("SHOW lock_timeout")
    execute "SET lock_timeout = '5s'"
    yield
  ensure
    execute "SET lock_timeout = #{connection.quote(previous_timeout)}" if previous_timeout
  end
end
