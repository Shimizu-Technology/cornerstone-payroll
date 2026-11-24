# frozen_string_literal: true

class AddEmployeeDocumentWithdrawalReason < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_documents, :withdrawal_reason, :string
  end
end
