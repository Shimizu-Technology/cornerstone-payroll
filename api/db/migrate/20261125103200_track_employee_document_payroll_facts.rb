# frozen_string_literal: true

class TrackEmployeeDocumentPayrollFacts < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_documents, :payroll_facts_sha256, :string
    add_column :employee_documents, :payroll_facts_checked_at, :datetime
  end
end
