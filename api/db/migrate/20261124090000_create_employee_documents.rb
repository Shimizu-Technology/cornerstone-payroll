# frozen_string_literal: true

class CreateEmployeeDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_documents do |t|
      t.references :company, null: false, foreign_key: true
      t.bigint :payroll_item_id
      t.bigint :historical_paycheck_id
      t.bigint :employee_id
      t.integer :tax_year
      t.integer :revision, null: false
      t.string :status, null: false, default: "posted"
      t.string :storage_key, null: false
      t.string :sha256, null: false
      t.datetime :posted_at, null: false
      t.boolean :corrected, null: false, default: false
      t.bigint :replaces_document_id
      t.string :payment_line
      t.timestamps

      t.index [ :id, :company_id ], unique: true
      t.index [ :payroll_item_id, :revision ], unique: true, where: "payroll_item_id IS NOT NULL"
      t.index [ :historical_paycheck_id, :revision ], unique: true, where: "historical_paycheck_id IS NOT NULL"
      t.index [ :employee_id, :tax_year, :revision ], unique: true, where: "tax_year IS NOT NULL"
      t.index :replaces_document_id

      t.check_constraint <<~SQL.squish, name: "employee_documents_one_source"
        num_nonnulls(payroll_item_id, historical_paycheck_id, tax_year) = 1
        AND (tax_year IS NULL) = (employee_id IS NULL)
      SQL
      t.check_constraint "status IN ('posted', 'replaced', 'withdrawn')", name: "employee_documents_valid_status"
      t.check_constraint "revision > 0", name: "employee_documents_positive_revision"
      t.check_constraint "sha256 ~ '^[a-f0-9]{64}$'", name: "employee_documents_sha256"
      t.check_constraint "corrected = (replaces_document_id IS NOT NULL) AND replaces_document_id IS DISTINCT FROM id",
        name: "employee_documents_correction_link"
    end

    {
      payroll_items: :payroll_item_id, historical_paychecks: :historical_paycheck_id,
      employees: :employee_id, employee_documents: :replaces_document_id
    }.each do |table, source|
      add_foreign_key :employee_documents, table, column: [ source, :company_id ],
        primary_key: [ :id, :company_id ], name: "fk_employee_documents_#{source}"
    end

    reversible do |direction|
      direction.up do
        execute File.read(Rails.root.join("db/rls_policies.sql"))
        execute "SELECT pg_temp.install_company_policy(current_schema(), 'employee_documents', NULL, NULL, false)"
      end
    end
  end
end
