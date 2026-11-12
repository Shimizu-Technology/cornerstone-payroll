# frozen_string_literal: true

class BridgePayrollSubmissionImports < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_submission_imports do |t|
      t.references :payroll_submission, null: false, foreign_key: true
      t.references :payroll_import, null: false, foreign_key: true
      t.references :current_submission, null: false, foreign_key: { to_table: :payroll_submissions }
      t.references :selected_by, null: false, foreign_key: { to_table: :users }
      t.text :superseded_reason
      t.datetime :applied_at
      t.timestamps
      t.index [ :payroll_submission_id, :payroll_import_id, :current_submission_id ], unique: true, name: "idx_portal_import_selection"
    end
    add_reference :payroll_intake_documents, :payroll_submission_document, foreign_key: true, index: { name: "idx_intake_document_portal_source" }
  end
end
