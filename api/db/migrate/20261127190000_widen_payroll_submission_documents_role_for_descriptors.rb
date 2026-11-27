# frozen_string_literal: true

# Track C B5-B6:
# Widens payroll_submission_documents_role from the legacy MoSa-only allowlist
# ('revel_payroll', 'changes_workbook', 'attachment') to a strict snake_case
# role format check so descriptor-defined portal submission roles (for future
# adapters such as universal workbooks) can be persisted without new DDL per
# adapter. Application-level validation in PayrollSubmissionDocument restricts
# roles strictly to registered descriptor portal roles plus 'attachment'.
#
# Note for future submittable descriptors: `revel_payroll` and `changes_workbook`
# already have partial unique indexes enforcing at most one document per role per
# submission. When adding a new portal-submittable descriptor role with `max: 1`,
# add a matching partial unique index in its migration.
#
# Uses SET LOCAL lock_timeout = '5s' and NOT VALID + validate outside the lock.
class WidenPayrollSubmissionDocumentsRoleForDescriptors < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  CONSTRAINT_NAME = "payroll_submission_documents_role"
  EXPANDED_TMP = "payroll_submission_documents_role_descriptor_tmp"
  ORIGINAL_TMP = "payroll_submission_documents_role_original_tmp"

  EXPANDED_EXPR = "role::text ~ '^[a-z][a-z0-9_]{0,63}$'"
  ORIGINAL_EXPR = "role::text = ANY (ARRAY['revel_payroll'::character varying::text, 'changes_workbook'::character varying::text, 'attachment'::character varying::text])"

  def up
    swap_role_constraint!(EXPANDED_EXPR, EXPANDED_TMP)
  end

  def down
    swap_role_constraint!(ORIGINAL_EXPR, ORIGINAL_TMP)
  end

  private

  def swap_role_constraint!(expression, temporary_name)
    unless connection.check_constraint_exists?(:payroll_submission_documents, name: temporary_name)
      with_lock_timeout do
        add_check_constraint :payroll_submission_documents,
                             expression,
                             name: temporary_name,
                             validate: false
      end
    end

    begin
      validate_check_constraint :payroll_submission_documents, name: temporary_name
    rescue StandardError
      with_lock_timeout do
        if connection.check_constraint_exists?(:payroll_submission_documents, name: temporary_name)
          remove_check_constraint :payroll_submission_documents, name: temporary_name
        end
      end
      raise
    end

    with_lock_timeout do
      [ EXPANDED_TMP, ORIGINAL_TMP ].each do |name|
        next if name == temporary_name
        next unless connection.check_constraint_exists?(:payroll_submission_documents, name: name)

        remove_check_constraint :payroll_submission_documents, name: name
      end

      if connection.check_constraint_exists?(:payroll_submission_documents, name: CONSTRAINT_NAME)
        remove_check_constraint :payroll_submission_documents, name: CONSTRAINT_NAME
      end

      execute "ALTER TABLE payroll_submission_documents RENAME CONSTRAINT " \
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
