# frozen_string_literal: true

# Track C B8:
# 1. Widens payroll_intake_documents_source_role from the legacy allowlist to a
#    strict snake_case role format check matching payroll_submission_documents_role,
#    so descriptor-defined file roles (such as cornerstone_workbook) can be
#    persisted without new DDL per adapter. Application-level validation in
#    PayrollIntakeDocument restricts roles strictly to core + registered
#    descriptor file roles.
# 2. Adds the partial unique index for the cornerstone_workbook portal role
#    (`payroll_workbook`, max: 1) matching `revel_payroll` and `changes_workbook`.
#
# Safety guarantees:
# - Explicit lock_timeout and statement_timeout on transactional AND concurrent DDL.
# - Checks pg_index.indisvalid before skipping the concurrent unique index, dropping
#   and rebuilding any invalid leftover index from a prior interrupted attempt.
# - Refuses rollback with ActiveRecord::IrreversibleMigration before mutating any
#   index or constraint if any payroll_intake_documents row uses a non-legacy role.
class WidenPayrollIntakeDocumentRolesForUniversalWorkbook < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  CONSTRAINT_NAME = "payroll_intake_documents_source_role"
  EXPANDED_TMP = "payroll_intake_documents_source_role_descriptor_tmp"
  ORIGINAL_TMP = "payroll_intake_documents_source_role_original_tmp"

  LEGACY_ROLES = %w[
    pasted_email
    email_attachment
    revel_hours
    supplemental_workbook
    supporting_document
    legacy_source
  ].freeze

  EXPANDED_EXPR = "source_role::text ~ '^[a-z][a-z0-9_]{0,63}$'"
  ORIGINAL_EXPR = "source_role::text = ANY (ARRAY['pasted_email'::character varying::text, 'email_attachment'::character varying::text, 'revel_hours'::character varying::text, 'supplemental_workbook'::character varying::text, 'supporting_document'::character varying::text, 'legacy_source'::character varying::text])"

  WORKBOOK_INDEX_NAME = "idx_payroll_submission_documents_one_payroll_workbook"

  def up
    swap_role_constraint!(EXPANDED_EXPR, EXPANDED_TMP)
    ensure_valid_unique_workbook_index!
  end

  def down
    ensure_safe_rollback!
    swap_role_constraint!(ORIGINAL_EXPR, ORIGINAL_TMP)
    drop_workbook_index_if_present!
  end

  private

  def ensure_safe_rollback!
    quoted_roles = LEGACY_ROLES.map { |role| connection.quote(role) }.join(", ")
    rows = connection.select_rows(<<~SQL.squish)
      SELECT source_role, COUNT(*)
      FROM payroll_intake_documents
      WHERE source_role NOT IN (#{quoted_roles})
      GROUP BY source_role
      ORDER BY source_role
    SQL
    return if rows.empty?

    summary = rows.map { |role, count| "#{role} (#{count})" }.join(", ")
    raise ActiveRecord::IrreversibleMigration,
          "Cannot roll back #{CONSTRAINT_NAME} while payroll_intake_documents contains non-legacy source_role(s): #{summary}. " \
          "Migrate or remove those rows before reverting."
  end

  def ensure_valid_unique_workbook_index!
    state = index_validity_state(WORKBOOK_INDEX_NAME)
    return if state == :valid

    if state == :invalid
      with_session_timeouts do
        execute "DROP INDEX CONCURRENTLY IF EXISTS #{connection.quote_table_name(WORKBOOK_INDEX_NAME)}"
      end
    end

    with_session_timeouts do
      add_index :payroll_submission_documents,
                :payroll_submission_id,
                unique: true,
                where: "role = 'payroll_workbook'",
                name: WORKBOOK_INDEX_NAME,
                algorithm: :concurrently
    end
  end

  def drop_workbook_index_if_present!
    return if index_validity_state(WORKBOOK_INDEX_NAME) == :missing

    with_session_timeouts do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{connection.quote_table_name(WORKBOOK_INDEX_NAME)}"
    end
  end

  def index_validity_state(index_name)
    row = connection.select_one(<<~SQL.squish)
      SELECT i.indisvalid
      FROM pg_class c
      JOIN pg_index i ON i.indexrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema()
        AND c.relname = #{connection.quote(index_name)}
    SQL
    return :missing if row.nil?

    ActiveModel::Type::Boolean.new.cast(row["indisvalid"]) ? :valid : :invalid
  end

  def swap_role_constraint!(expression, temporary_name)
    unless connection.check_constraint_exists?(:payroll_intake_documents, name: temporary_name)
      with_lock_timeout do
        add_check_constraint :payroll_intake_documents,
                             expression,
                             name: temporary_name,
                             validate: false
      end
    end

    begin
      with_session_timeouts do
        validate_check_constraint :payroll_intake_documents, name: temporary_name
      end
    rescue StandardError
      with_lock_timeout do
        if connection.check_constraint_exists?(:payroll_intake_documents, name: temporary_name)
          remove_check_constraint :payroll_intake_documents, name: temporary_name
        end
      end
      raise
    end

    with_lock_timeout do
      [ EXPANDED_TMP, ORIGINAL_TMP ].each do |name|
        next if name == temporary_name
        next unless connection.check_constraint_exists?(:payroll_intake_documents, name: name)

        remove_check_constraint :payroll_intake_documents, name: name
      end

      if connection.check_constraint_exists?(:payroll_intake_documents, name: CONSTRAINT_NAME)
        remove_check_constraint :payroll_intake_documents, name: CONSTRAINT_NAME
      end

      execute "ALTER TABLE payroll_intake_documents RENAME CONSTRAINT " \
              "#{connection.quote_column_name(temporary_name)} TO #{connection.quote_column_name(CONSTRAINT_NAME)}"
    end
  end

  def with_lock_timeout
    connection.transaction do
      execute "SET LOCAL lock_timeout = '5s'"
      execute "SET LOCAL statement_timeout = '30s'"
      yield
    end
  end

  def with_session_timeouts(lock_timeout: "5s", statement_timeout: "60s")
    previous_lock = connection.select_value("SHOW lock_timeout")
    previous_statement = connection.select_value("SHOW statement_timeout")
    execute "SET lock_timeout = #{connection.quote(lock_timeout)}"
    execute "SET statement_timeout = #{connection.quote(statement_timeout)}"
    yield
  ensure
    execute "SET lock_timeout = #{connection.quote(previous_lock)}" if previous_lock
    execute "SET statement_timeout = #{connection.quote(previous_statement)}" if previous_statement
  end
end
