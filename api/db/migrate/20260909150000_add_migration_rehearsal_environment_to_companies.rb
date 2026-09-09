# frozen_string_literal: true

class AddMigrationRehearsalEnvironmentToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :payroll_environment, :string, null: false, default: "live"
    add_reference :companies, :migration_source_company, foreign_key: { to_table: :companies }, null: true
    add_reference :companies, :migration_source_batch, foreign_key: { to_table: :historical_import_batches }, null: true
    add_column :companies, :migration_rehearsal_status, :string
    add_reference :companies, :migration_rehearsal_created_by, foreign_key: { to_table: :users }, null: true
    add_column :companies, :migration_rehearsal_created_at, :datetime
    add_column :companies, :migration_rehearsal_completed_at, :datetime
    add_column :companies, :migration_rehearsal_error, :text

    add_index :companies, [ :migration_source_company_id, :active ],
              name: "idx_companies_active_migration_rehearsals",
              unique: true,
              where: "payroll_environment = 'migration_rehearsal' AND active = TRUE"

    remove_index :companies, :ein, unique: true
    add_index :companies, :ein, unique: true, where: "payroll_environment = 'live'",
              name: "index_live_companies_on_ein"

    add_check_constraint :companies,
                         "payroll_environment IN ('live', 'migration_rehearsal')",
                         name: "companies_payroll_environment_check"
    add_check_constraint :companies,
                         "migration_rehearsal_status IS NULL OR migration_rehearsal_status IN ('pending', 'ready', 'failed')",
                         name: "companies_migration_rehearsal_status_check"
    add_check_constraint :companies,
                         <<~SQL.squish,
                           (payroll_environment = 'live' AND migration_source_company_id IS NULL AND migration_source_batch_id IS NULL AND migration_rehearsal_status IS NULL)
                           OR
                           (payroll_environment = 'migration_rehearsal' AND migration_source_company_id IS NOT NULL AND migration_source_batch_id IS NOT NULL AND migration_rehearsal_status IS NOT NULL)
                         SQL
                         name: "companies_migration_rehearsal_shape_check"
  end
end
