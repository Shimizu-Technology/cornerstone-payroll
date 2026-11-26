# frozen_string_literal: true

# The notice owed to an employee's previous email address after the address
# on file changed (EmployeeLinks::EmailChange). The row is written in the
# same transaction as the change, so a queue outage can't lose the notice;
# the job sends it after commit and a recurring sweep retries what's left.
#
# Company-protected like the other employee tables: its policy is staged
# here and it follows the database's current enforcement phase.
class CreateEmployeeEmailChangeNotices < ActiveRecord::Migration[8.1]
  STATUSES = %w[pending sent skipped failed].freeze

  def up
    execute "SET LOCAL lock_timeout = '5s'"
    create_table :employee_email_change_notices do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }, index: true
      t.references :employee, null: false, foreign_key: { on_delete: :restrict }, index: true
      # One per committed change; also the delivery's idempotency key.
      t.string :change_id, null: false, limit: 36
      t.string :recipient_email, null: false
      t.string :status, null: false, default: "pending", limit: 20
      t.integer :attempts, null: false, default: 0
      t.datetime :sent_at
      t.timestamps null: false

      t.index :change_id, unique: true
      t.index %i[status updated_at], where: "status IN ('pending', 'failed')", name: "idx_employee_email_change_notices_unsent"
      t.check_constraint "status IN (#{STATUSES.map { |status| "'#{status}'" }.join(', ')})",
        name: "employee_email_change_notices_status_check"
      t.check_constraint "attempts >= 0", name: "employee_email_change_notices_attempts_check"
    end
    stage_company_policy!
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    drop_table :employee_email_change_notices
  end

  private

  def stage_company_policy!
    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'employee_email_change_notices', NULL, NULL, false)"
    return unless connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'employee_account_links'::regclass")

    execute "ALTER TABLE employee_email_change_notices ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE employee_email_change_notices FORCE ROW LEVEL SECURITY"
  end
end
