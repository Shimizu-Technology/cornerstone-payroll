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
# Uses SET LOCAL lock_timeout = '5s', NOT VALID + validate outside the lock,
# and algorithm: :concurrently for index creation.
class WidenPayrollIntakeDocumentRolesForUniversalWorkbook < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  CONSTRAINT_NAME = "payroll_intake_documents_source_role"
  EXPANDED_TMP = "payroll_intake_documents_source_role_descriptor_tmp"
  ORIGINAL_TMP = "payroll_intake_documents_source_role_original_tmp"

  EXPANDED_EXPR = "source_role::text ~ '^[a-z][a-z0-9_]{0,63}$'"
  ORIGINAL_EXPR = "source_role::text = ANY (ARRAY['pasted_email'::character varying::text, 'email_attachment'::character varying::text, 'revel_hours'::character varying::text, 'supplemental_workbook'::character varying::text, 'supporting_document'::character varying::text, 'legacy_source'::character varying::text])"

  WORKBOOK_INDEX_NAME = "idx_payroll_submission_documents_one_payroll_workbook"

  def up
    swap_role_constraint!(EXPANDED_EXPR, EXPANDED_TMP)
    unless connection.index_exists?(:payroll_submission_documents, :payroll_submission_id, name: WORKBOOK_INDEX_NAME)
      add_index :payroll_submission_documents,
                :payroll_submission_id,
                unique: true,
                where: "role = 'payroll_workbook'",
                name: WORKBOOK_INDEX_NAME,
                algorithm: :concurrently
    end
  end

  def down
    if connection.index_exists?(:payroll_submission_documents, :payroll_submission_id, name: WORKBOOK_INDEX_NAME)
      remove_index :payroll_submission_documents, name: WORKBOOK_INDEX_NAME, algorithm: :concurrently
    end
    swap_role_constraint!(ORIGINAL_EXPR, ORIGINAL_TMP)
  end

  private

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
      validate_check_constraint :payroll_intake_documents, name: temporary_name
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
      yield
    end
  end
end
