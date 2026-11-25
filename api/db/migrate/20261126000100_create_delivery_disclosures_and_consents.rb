# frozen_string_literal: true

class CreateDeliveryDisclosuresAndConsents < ActiveRecord::Migration[8.1]
  def up
    create_table :delivery_disclosures do |t|
      t.string :kind, null: false
      t.string :version, null: false
      t.string :title, null: false
      t.text :text, null: false
      t.string :digest, null: false, limit: 64
      t.string :status, null: false, default: "draft"
      t.datetime :published_at
      t.timestamps

      t.index %i[kind version], unique: true, name: "idx_delivery_disclosures_kind_version"
      t.index %i[kind status published_at id], name: "idx_delivery_disclosures_current"
      t.check_constraint "kind IN ('pay_statements', 'w2gu')", name: "delivery_disclosures_kind_check"
      t.check_constraint "status IN ('draft', 'approved')", name: "delivery_disclosures_status_check"
      t.check_constraint "digest ~ '^[0-9a-f]{64}$'", name: "delivery_disclosures_digest_check"
    end

    create_table :delivery_consents do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: { on_delete: :restrict }, index: true
      t.references :employee, null: false, index: false
      t.references :employee_account_link, null: false, index: true
      t.references :delivery_disclosure, null: false, foreign_key: { on_delete: :restrict }, index: true
      t.string :kind, null: false
      t.string :disclosure_version, null: false
      t.string :disclosure_digest, null: false, limit: 64
      t.datetime :given_at, null: false
      t.string :ip_address, limit: 64
      t.string :user_agent, limit: 512
      t.string :method, null: false
      t.datetime :access_proof_verified_at
      t.datetime :withdrawn_at
      t.references :withdrawn_by_user, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.string :withdrawn_ip_address, limit: 64
      t.string :withdrawn_user_agent, limit: 512
      t.timestamps

      t.index %i[company_id employee_id kind], unique: true, where: "withdrawn_at IS NULL",
        name: "idx_delivery_consents_active_unique"
      t.index %i[company_id employee_id kind given_at id], name: "idx_delivery_consents_employee_kind"
      t.check_constraint "kind IN ('pay_statements', 'w2gu')", name: "delivery_consents_kind_check"
      t.check_constraint "disclosure_digest ~ '^[0-9a-f]{64}$'", name: "delivery_consents_digest_check"
      t.check_constraint "method IN ('employee_portal_checkbox', 'employee_portal_pdf_verified')",
        name: "delivery_consents_method_check"
      t.check_constraint "withdrawn_at IS NULL OR withdrawn_at >= given_at",
        name: "delivery_consents_withdrawn_after_given_check"
      t.check_constraint "kind <> 'w2gu' OR access_proof_verified_at IS NOT NULL",
        name: "delivery_consents_w2gu_access_proof_check"
    end

    add_foreign_key :delivery_consents, :employees,
      column: %i[employee_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_delivery_consents_employee"
    add_foreign_key :delivery_consents, :employee_account_links,
      column: %i[employee_account_link_id employee_id company_id], primary_key: %i[id employee_id company_id],
      on_delete: :restrict, name: "fk_delivery_consents_link"

    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'delivery_consents', NULL, NULL, false)"
  end

  def down
    drop_table :delivery_consents
    drop_table :delivery_disclosures
  end
end
