# frozen_string_literal: true

class RecordSubmissionWorkbookChoices < ActiveRecord::Migration[8.1]
  def change
    # NULL means a legacy revision: never invent a client's "none" declaration.
    add_column :payroll_submissions, :workbook_choice, :string
    add_check_constraint :payroll_submissions, "workbook_choice IS NULL OR workbook_choice IN ('attach', 'link', 'none')", name: "submission_workbook_choice"
    add_column :payroll_submission_imports, :source_route, :string, null: false, default: "portal"
    add_reference :payroll_submission_imports, :staff_workbook_document, foreign_key: { to_table: :payroll_intake_documents }
    add_reference :payroll_submission_imports, :staff_workbook_attached_by, foreign_key: { to_table: :users }
    add_column :payroll_submission_imports, :staff_workbook_attached_at, :datetime
  end
end
