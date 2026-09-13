# frozen_string_literal: true

class CreateEmployeeDocumentRequirements < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :document_readiness_required, :boolean, null: false, default: false
    add_index :employees, [ :id, :company_id ], unique: true, name: "idx_employees_document_readiness_tenant_key"
    add_index :client_documents, [ :id, :company_id ], unique: true, name: "idx_client_documents_readiness_tenant_key"

    create_table :employee_document_requirements do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: false
      t.references :client_document, null: true, foreign_key: false
      t.references :created_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :reviewed_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :requirement_type, null: false
      t.string :label, null: false
      t.string :status, null: false, default: "missing"
      t.boolean :required_for_payroll, null: false, default: true
      t.date :due_on
      t.datetime :received_at
      t.datetime :reviewed_at
      t.text :review_note
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :employee_document_requirements,
      [ :employee_id, :requirement_type ],
      unique: true,
      name: "index_employee_document_requirements_on_employee_and_type"
    add_index :employee_document_requirements,
      [ :company_id, :status ],
      name: "index_employee_document_requirements_on_company_and_status"
    add_index :employee_document_requirements,
      [ :id, :company_id ],
      unique: true,
      name: "idx_employee_document_requirements_tenant_key"
    add_foreign_key :employee_document_requirements,
      :employees,
      column: [ :employee_id, :company_id ],
      primary_key: [ :id, :company_id ],
      name: "fk_employee_document_requirements_employee_tenant"
    add_foreign_key :employee_document_requirements,
      :client_documents,
      column: [ :client_document_id, :company_id ],
      primary_key: [ :id, :company_id ],
      name: "fk_employee_document_requirements_document_tenant"

    create_table :employee_document_requirement_events do |t|
      t.references :employee_document_requirement, null: false, foreign_key: false
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: false
      t.references :client_document, null: true, foreign_key: false
      t.references :actor, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :event_type, null: false
      t.string :from_status
      t.string :to_status, null: false
      t.string :document_title
      t.text :note
      t.timestamps
    end

    add_index :employee_document_requirement_events,
      [ :employee_document_requirement_id, :created_at ],
      name: "index_employee_document_requirement_events_on_history"
    add_foreign_key :employee_document_requirement_events,
      :employee_document_requirements,
      column: [ :employee_document_requirement_id, :company_id ],
      primary_key: [ :id, :company_id ],
      name: "fk_employee_document_requirement_events_requirement_tenant"
    add_foreign_key :employee_document_requirement_events,
      :employees,
      column: [ :employee_id, :company_id ],
      primary_key: [ :id, :company_id ],
      name: "fk_employee_document_requirement_events_employee_tenant"
    add_foreign_key :employee_document_requirement_events,
      :client_documents,
      column: [ :client_document_id, :company_id ],
      primary_key: [ :id, :company_id ],
      name: "fk_employee_document_requirement_events_document_tenant"
  end
end
