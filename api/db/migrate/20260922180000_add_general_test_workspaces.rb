# frozen_string_literal: true

class AddGeneralTestWorkspaces < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :companies, name: "companies_test_workspace_purpose_check"
    add_check_constraint :companies,
                         "test_workspace_purpose IS NULL OR test_workspace_purpose IN ('sandbox', 'migration_rehearsal', 'training_replay', 'backup_snapshot')",
                         name: "companies_test_workspace_purpose_check"

    remove_index :companies, name: "idx_companies_active_test_workspaces"
    add_index :companies,
              [ :migration_source_company_id, :test_workspace_purpose ],
              unique: true,
              name: "idx_companies_active_test_workspaces",
              where: <<~SQL.squish
                payroll_environment = 'migration_rehearsal'
                AND active = TRUE
                AND test_workspace_archived_at IS NULL
                AND test_workspace_purpose IN ('migration_rehearsal', 'training_replay', 'backup_snapshot')
              SQL
  end

  def down
    sandbox_count = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM companies WHERE test_workspace_purpose = 'sandbox'
    SQL
    if sandbox_count.positive?
      raise ActiveRecord::IrreversibleMigration,
            "Archive and remove general test workspaces before rolling back this migration"
    end

    remove_index :companies, name: "idx_companies_active_test_workspaces"
    add_index :companies,
              [ :migration_source_company_id, :test_workspace_purpose ],
              unique: true,
              name: "idx_companies_active_test_workspaces",
              where: "payroll_environment = 'migration_rehearsal' AND active = TRUE AND test_workspace_archived_at IS NULL"

    remove_check_constraint :companies, name: "companies_test_workspace_purpose_check"
    add_check_constraint :companies,
                         "test_workspace_purpose IS NULL OR test_workspace_purpose IN ('migration_rehearsal', 'training_replay', 'backup_snapshot')",
                         name: "companies_test_workspace_purpose_check"
  end
end
