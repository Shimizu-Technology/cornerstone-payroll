# frozen_string_literal: true

# Staging and production independently used migration version 20260921010000.
# Production used it for test workspaces; staging used it for AIRE onboarding.
# This migration makes both schemas converge without rerunning either historical
# migration against a database where that version already means something else.
class ReconcileStagingMainSchema < ActiveRecord::Migration[8.1]
  WORKSPACE_COMPANY_COLUMNS = %i[
    test_workspace_purpose
    test_workspace_manifest
    test_workspace_expires_at
    test_workspace_archived_at
    test_workspace_sealed_at
  ].freeze
  WORKSPACE_ASSIGNMENT_COLUMNS = %i[workspace_access_level expires_at granted_by_id].freeze

  def up
    ensure_aire_onboarding_review_source!
    ensure_test_workspace_foundation!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "This migration reconciles already-deployed staging and production schemas"
  end

  private

  def ensure_aire_onboarding_review_source!
    remove_check_constraint :employees, name: "employees_configuration_source_check" if
      check_constraint_exists?(:employees, name: "employees_configuration_source_check")
    add_check_constraint :employees,
                         "configuration_source IS NULL OR configuration_source IN ('quickbooks_history', 'aire_onboarding')",
                         name: "employees_configuration_source_check"
  end

  def ensure_test_workspace_foundation!
    existing_company_columns = WORKSPACE_COMPANY_COLUMNS.select { |column| column_exists?(:companies, column) }
    existing_assignment_columns = WORKSPACE_ASSIGNMENT_COLUMNS.select do |column|
      column_exists?(:company_assignments, column)
    end

    return if existing_company_columns == WORKSPACE_COMPANY_COLUMNS &&
      existing_assignment_columns == WORKSPACE_ASSIGNMENT_COLUMNS

    if existing_company_columns.any? || existing_assignment_columns.any?
      raise "Test workspace schema is partially present; review it before continuing"
    end

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
end
