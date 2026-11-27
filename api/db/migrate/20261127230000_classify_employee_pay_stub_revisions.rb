# frozen_string_literal: true

class ClassifyEmployeePayStubRevisions < ActiveRecord::Migration[8.1]
  def up
    add_column :employee_documents, :printed_figures_sha256, :string
    add_column :employee_documents, :money_changed, :boolean
    add_column :employee_documents, :current_figures_sha256, :string
    add_column :employee_documents, :correction_label, :boolean
    add_column :employee_documents, :ytd_changed, :boolean
    remove_check_constraint :employee_document_notices, name: "employee_document_notices_kind"
    add_check_constraint :employee_document_notices,
      "kind IN ('w2gu_available', 'pay_stub_corrected')", name: "employee_document_notices_kind"
  end

  def down
    remove_check_constraint :employee_document_notices, name: "employee_document_notices_kind"
    add_check_constraint :employee_document_notices, "kind = 'w2gu_available'", name: "employee_document_notices_kind"
    remove_column :employee_documents, :ytd_changed
    remove_column :employee_documents, :correction_label
    remove_column :employee_documents, :current_figures_sha256
    remove_column :employee_documents, :money_changed
    remove_column :employee_documents, :printed_figures_sha256
  end
end
