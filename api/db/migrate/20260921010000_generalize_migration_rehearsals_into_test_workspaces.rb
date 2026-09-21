# frozen_string_literal: true

class GeneralizeMigrationRehearsalsIntoTestWorkspaces < ActiveRecord::Migration[8.1]
  def up
    add_column :companies, :test_workspace_purpose, :string
    add_column :companies, :test_workspace_manifest, :jsonb, null: false, default: {}
    add_column :companies, :test_workspace_expires_at, :datetime
    add_column :companies, :test_workspace_archived_at, :datetime
    add_column :companies, :test_workspace_sealed_at, :datetime

    execute <<~SQL.squish
      UPDATE companies
      SET test_workspace_purpose = 'migration_rehearsal'
      WHERE payroll_environment = 'migration_rehearsal'
    SQL

    remove_index :companies, name: "idx_companies_active_migration_rehearsals"
    add_index :companies,
              [ :migration_source_company_id, :test_workspace_purpose ],
              unique: true,
              name: "idx_companies_active_test_workspaces",
              where: "payroll_environment = 'migration_rehearsal' AND active = TRUE AND test_workspace_archived_at IS NULL"

    remove_check_constraint :companies, name: "companies_migration_rehearsal_shape_check"
    add_check_constraint :companies,
                         "test_workspace_purpose IS NULL OR test_workspace_purpose IN ('migration_rehearsal', 'training_replay', 'backup_snapshot')",
                         name: "companies_test_workspace_purpose_check"
    add_check_constraint :companies,
                         <<~SQL.squish,
                           (
                             payroll_environment = 'live'
                             AND migration_source_company_id IS NULL
                             AND migration_source_batch_id IS NULL
                             AND migration_rehearsal_status IS NULL
                             AND test_workspace_purpose IS NULL
                           )
                           OR
                           (
                             payroll_environment = 'migration_rehearsal'
                             AND migration_source_company_id IS NOT NULL
                             AND migration_rehearsal_status IS NOT NULL
                             AND test_workspace_purpose IS NOT NULL
                             AND (
                               test_workspace_purpose <> 'migration_rehearsal'
                               OR migration_source_batch_id IS NOT NULL
                             )
                           )
                         SQL
                         name: "companies_test_workspace_shape_check"

    add_column :company_assignments, :workspace_access_level, :string
    add_column :company_assignments, :expires_at, :datetime
    add_reference :company_assignments, :granted_by, foreign_key: { to_table: :users }, null: true

    execute <<~SQL.squish
      UPDATE company_assignments
      SET workspace_access_level = 'workspace_admin'
      FROM companies
      WHERE company_assignments.company_id = companies.id
        AND companies.payroll_environment = 'migration_rehearsal'
    SQL

    add_check_constraint :company_assignments,
                         "workspace_access_level IS NULL OR workspace_access_level IN ('operator', 'reviewer', 'workspace_admin')",
                         name: "company_assignments_workspace_access_level_check"
  end

  def down
    non_rehearsal_workspaces_exist = select_value(<<~SQL.squish)
      SELECT EXISTS (
        SELECT 1
        FROM companies
        WHERE payroll_environment = 'migration_rehearsal'
          AND test_workspace_purpose <> 'migration_rehearsal'
      )
    SQL

    if non_rehearsal_workspaces_exist
      raise ActiveRecord::IrreversibleMigration,
            "Archive or remove training and backup workspaces before rolling back this migration"
    end

    remove_check_constraint :company_assignments, name: "company_assignments_workspace_access_level_check"
    remove_reference :company_assignments, :granted_by, foreign_key: { to_table: :users }
    remove_column :company_assignments, :expires_at
    remove_column :company_assignments, :workspace_access_level

    remove_check_constraint :companies, name: "companies_test_workspace_shape_check"
    remove_check_constraint :companies, name: "companies_test_workspace_purpose_check"
    remove_index :companies, name: "idx_companies_active_test_workspaces"

    add_index :companies, [ :migration_source_company_id, :active ],
              name: "idx_companies_active_migration_rehearsals",
              unique: true,
              where: "payroll_environment = 'migration_rehearsal' AND active = TRUE"
    add_check_constraint :companies,
                         <<~SQL.squish,
                           (payroll_environment = 'live' AND migration_source_company_id IS NULL AND migration_source_batch_id IS NULL AND migration_rehearsal_status IS NULL)
                           OR
                           (payroll_environment = 'migration_rehearsal' AND migration_source_company_id IS NOT NULL AND migration_source_batch_id IS NOT NULL AND migration_rehearsal_status IS NOT NULL)
                         SQL
                         name: "companies_migration_rehearsal_shape_check"

    remove_column :companies, :test_workspace_sealed_at
    remove_column :companies, :test_workspace_archived_at
    remove_column :companies, :test_workspace_expires_at
    remove_column :companies, :test_workspace_manifest
    remove_column :companies, :test_workspace_purpose
  end
end
