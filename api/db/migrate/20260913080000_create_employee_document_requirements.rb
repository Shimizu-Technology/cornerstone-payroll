# frozen_string_literal: true

class CreateEmployeeDocumentRequirements < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :document_readiness_required, :boolean, null: false, default: false

    create_table :employee_document_requirements do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :client_document, null: true, foreign_key: { on_delete: :nullify }
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

    create_table :employee_document_requirement_events do |t|
      t.references :employee_document_requirement, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :client_document, null: true, foreign_key: { on_delete: :nullify }
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
  end
end
