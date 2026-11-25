# frozen_string_literal: true

# One email notice per posted employee document (M4-5: the W-2GU "IMPORTANT
# TAX RETURN DOCUMENT AVAILABLE" notice), with what the provider later
# reports about delivery. delivery_status stays "unknown" until a signed
# provider event arrives; a bounce is what 26 CFR 31.6051-1(j) needs tracked
# before electronic-only W-2s can be switched on.
class CreateEmployeeDocumentNotices < ActiveRecord::Migration[8.1]
  def up
    create_table :employee_document_notices do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.bigint :employee_document_id, null: false
      t.bigint :employee_id, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.string :skip_reason
      t.string :recipient_email
      t.string :provider_message_id
      t.string :delivery_status, null: false, default: "unknown"
      t.string :bounce_type
      t.datetime :sent_at
      t.datetime :delivery_event_at
      t.integer :attempts, null: false, default: 0
      t.timestamps

      t.index %i[company_id employee_document_id kind], unique: true, name: "idx_employee_document_notices_once"
      t.index %i[company_id employee_id], name: "idx_employee_document_notices_employee"
      t.index :provider_message_id, unique: true, where: "provider_message_id IS NOT NULL",
        name: "idx_employee_document_notices_provider_message"
      t.check_constraint "kind IN ('w2gu_available')", name: "employee_document_notices_kind"
      t.check_constraint "status IN ('pending', 'sent', 'skipped', 'failed')", name: "employee_document_notices_status"
      t.check_constraint "delivery_status IN ('unknown', 'delivered', 'delayed', 'bounced', 'complained')",
        name: "employee_document_notices_delivery_status"
    end

    add_foreign_key :employee_document_notices, :employee_documents, column: %i[employee_document_id company_id],
      primary_key: %i[id company_id], name: "fk_employee_document_notices_document"
    add_foreign_key :employee_document_notices, :employees, column: %i[employee_id company_id],
      primary_key: %i[id company_id], name: "fk_employee_document_notices_employee"

    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'employee_document_notices', NULL, NULL, false)"
  end

  def down
    drop_table :employee_document_notices
  end
end
