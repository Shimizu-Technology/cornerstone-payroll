# frozen_string_literal: true

class AddClientManagementToCompanyAssignments < ActiveRecord::Migration[8.1]
  def change
    add_column :company_assignments, :client_management, :boolean, null: false, default: false
    add_check_constraint :company_assignments,
      "NOT client_management OR (workspace_access_level IS NULL AND granted_by_id IS NOT NULL)",
      name: "company_assignments_client_management_live_shape"
  end
end
