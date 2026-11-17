# frozen_string_literal: true

# A pay run's Activity feed finds its rows by metadata.pay_period_id.
class IndexAuditLogsByPayPeriod < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :audit_logs, "company_id, ((metadata ->> 'pay_period_id'))",
      name: "idx_audit_logs_company_pay_period", algorithm: :concurrently, if_not_exists: true
  end
end
