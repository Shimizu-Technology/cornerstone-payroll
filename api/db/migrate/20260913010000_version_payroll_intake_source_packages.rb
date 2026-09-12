# frozen_string_literal: true

class VersionPayrollIntakeSourcePackages < ActiveRecord::Migration[8.1]
  def up
    add_column :payroll_intake_sessions, :package_id, :string
    add_column :payroll_intake_sessions, :package_revision, :integer
    add_column :payroll_intake_sessions, :package_schema_version, :string, null: false, default: "legacy"

    execute <<~SQL.squish
      WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY pay_period_id ORDER BY created_at, id) AS revision
        FROM payroll_intake_sessions
      )
      UPDATE payroll_intake_sessions AS sessions
      SET package_id = CONCAT('legacy-', sessions.id),
          package_revision = ranked.revision
      FROM ranked
      WHERE sessions.id = ranked.id
    SQL

    change_column_null :payroll_intake_sessions, :package_id, false
    change_column_null :payroll_intake_sessions, :package_revision, false
    add_index :payroll_intake_sessions, :package_id, unique: true
    add_index :payroll_intake_sessions, [ :pay_period_id, :package_revision ], unique: true,
              name: "idx_payroll_intake_sessions_period_revision"
    add_check_constraint :payroll_intake_sessions, "package_revision > 0",
                         name: "payroll_intake_sessions_revision_positive"

    add_column :payroll_intake_documents, :source_role, :string, null: false, default: "legacy_source"
    add_column :payroll_intake_documents, :position, :integer, null: false, default: 0
    add_column :payroll_intake_documents, :byte_size, :bigint
    add_column :payroll_intake_documents, :sha256, :string
    add_column :payroll_intake_documents, :verification_status, :string, null: false, default: "legacy_unverified"
    add_column :payroll_intake_documents, :verified_at, :datetime
    add_column :payroll_intake_documents, :verification_error, :string

    execute <<~SQL.squish
      WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY payroll_intake_session_id ORDER BY created_at, id) - 1 AS position
        FROM payroll_intake_documents
      )
      UPDATE payroll_intake_documents AS documents
      SET position = ranked.position
      FROM ranked
      WHERE documents.id = ranked.id
    SQL

    add_index :payroll_intake_documents, [ :payroll_intake_session_id, :position ], unique: true,
              name: "idx_payroll_intake_documents_session_position"
    add_index :payroll_intake_documents, :storage_reference, unique: true,
              where: "storage_reference IS NOT NULL",
              name: "idx_payroll_intake_documents_storage_reference"
    add_check_constraint :payroll_intake_documents, "position >= 0",
                         name: "payroll_intake_documents_position_nonnegative"
    add_check_constraint :payroll_intake_documents,
                         "verification_status IN ('verified', 'failed', 'legacy_unverified')",
                         name: "payroll_intake_documents_verification_status"
    add_check_constraint :payroll_intake_documents,
                         "source_role IN ('pasted_email', 'email_attachment', 'revel_hours', 'supplemental_workbook', 'supporting_document', 'legacy_source')",
                         name: "payroll_intake_documents_source_role"
    add_check_constraint :payroll_intake_documents,
                         "verification_status != 'verified' OR (byte_size > 0 AND sha256 ~ '^[0-9a-f]{64}$' AND verified_at IS NOT NULL)",
                         name: "payroll_intake_documents_verified_fingerprint"
  end

  def down
    remove_check_constraint :payroll_intake_documents, name: "payroll_intake_documents_verified_fingerprint", if_exists: true
    remove_check_constraint :payroll_intake_documents, name: "payroll_intake_documents_source_role", if_exists: true
    remove_check_constraint :payroll_intake_documents, name: "payroll_intake_documents_verification_status", if_exists: true
    remove_check_constraint :payroll_intake_documents, name: "payroll_intake_documents_position_nonnegative", if_exists: true
    remove_index :payroll_intake_documents, name: "idx_payroll_intake_documents_storage_reference"
    remove_index :payroll_intake_documents, name: "idx_payroll_intake_documents_session_position"
    remove_columns :payroll_intake_documents, :source_role, :position, :byte_size, :sha256,
                   :verification_status, :verified_at, :verification_error

    remove_check_constraint :payroll_intake_sessions, name: "payroll_intake_sessions_revision_positive", if_exists: true
    remove_index :payroll_intake_sessions, name: "idx_payroll_intake_sessions_period_revision"
    remove_index :payroll_intake_sessions, :package_id
    remove_columns :payroll_intake_sessions, :package_id, :package_revision, :package_schema_version
  end
end
