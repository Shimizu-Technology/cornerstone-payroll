# frozen_string_literal: true

# A posted W-2GU copy staff withdraw (M4-5): who withdrew it, when, and the
# reason they gave. Until W-2c exists the app says a corrected form is being
# prepared.
class AddStaffWithdrawalToEmployeeDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_documents, :withdrawn_at, :datetime
    add_column :employee_documents, :withdrawn_by_id, :bigint
    add_column :employee_documents, :withdrawal_note, :text
    add_foreign_key :employee_documents, :users, column: :withdrawn_by_id
    add_index :employee_documents, :withdrawn_by_id, where: "withdrawn_by_id IS NOT NULL"
  end
end
