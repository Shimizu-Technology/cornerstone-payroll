# frozen_string_literal: true

class AddPaperFollowUpToEmployeeDocumentNotices < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_document_notices, :paper_bounced_on, :date
    add_column :employee_document_notices, :paper_due_on, :date
    add_column :employee_document_notices, :paper_mailed_on, :date
    add_reference :employee_document_notices, :paper_mailed_by, foreign_key: { to_table: :users }
  end
end
