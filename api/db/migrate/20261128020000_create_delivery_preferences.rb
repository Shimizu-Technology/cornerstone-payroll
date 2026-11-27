# frozen_string_literal: true

# An employee's explicit "keep paper" answer to the electronic-delivery
# question, one row per employee and kind. It records a choice and nothing
# more: paper delivery never depends on it (ElectronicOnlyReadiness keeps paper
# on for everyone until its gates pass), and an active DeliveryConsent always
# outranks it. Every write is also audited (employee_delivery_consents#keep_paper).
#
# Company-protected like delivery_consents: its policy is staged here and it
# follows the database's current enforcement phase.
class CreateDeliveryPreferences < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    create_table :delivery_preferences do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :employee, null: false, index: false
      t.references :employee_account_link, null: false, index: true
      t.references :user, null: false, foreign_key: { on_delete: :restrict }, index: true
      t.string :kind, null: false
      t.string :choice, null: false, default: "keep_paper"
      t.datetime :recorded_at, null: false
      t.string :ip_address, limit: 64
      t.string :user_agent, limit: 512
      t.timestamps null: false

      t.index %i[company_id employee_id kind], unique: true, name: "idx_delivery_preferences_employee_kind"
      t.check_constraint "kind IN ('pay_statements', 'w2gu')", name: "delivery_preferences_kind_check"
      t.check_constraint "choice IN ('keep_paper')", name: "delivery_preferences_choice_check"
    end

    add_foreign_key :delivery_preferences, :employees,
      column: %i[employee_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_delivery_preferences_employee"
    add_foreign_key :delivery_preferences, :employee_account_links,
      column: %i[employee_account_link_id employee_id company_id], primary_key: %i[id employee_id company_id],
      on_delete: :restrict, name: "fk_delivery_preferences_link"

    stage_company_policy!
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    drop_table :delivery_preferences
  end

  private

  def stage_company_policy!
    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'delivery_preferences', NULL, NULL, false)"
    return unless connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'employee_account_links'::regclass")

    execute "ALTER TABLE delivery_preferences ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE delivery_preferences FORCE ROW LEVEL SECURITY"
  end
end
