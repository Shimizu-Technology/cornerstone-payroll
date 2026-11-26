# frozen_string_literal: true

class AddCornerstonePayrollReviewOverride < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    add_column :pay_periods, :client_approval_retained, :boolean, default: false, null: false
    add_column :payroll_review_packages, :override_reason, :text
    add_column :payroll_review_packages, :self_override, :boolean, default: false, null: false

    replace_check "approval_method_check", "approval_method IS NULL OR approval_method IN ('client_portal', 'email_attestation', 'cornerstone_override')"
    replace_check "approval_shape", <<~SQL.squish
      (
        (status = 'approved' AND approved_at IS NOT NULL AND approved_by_id IS NOT NULL
          AND approval_recorded_by_id IS NOT NULL AND approval_method IS NOT NULL
          AND approval_acknowledgement IS NOT NULL)
        OR (status = 'pending' AND approved_at IS NULL AND approved_by_id IS NULL
          AND approval_recorded_by_id IS NULL AND approval_method IS NULL AND approval_acknowledgement IS NULL)
        OR status = 'superseded'
      )
      AND (status != 'approved' OR approval_method != 'email_attestation'
        OR NULLIF(btrim(approval_evidence_reference), '') IS NOT NULL)
      AND (status != 'approved' OR approval_method != 'client_portal' OR approved_by_id = approval_recorded_by_id)
      AND (CASE WHEN approval_method = 'cornerstone_override' THEN
        char_length(btrim(override_reason)) BETWEEN 10 AND 500
        AND approved_by_id = approval_recorded_by_id
        AND approval_acknowledgement = 'I am approving this exact payroll revision for the client under Cornerstone authority.'
      ELSE
        override_reason IS NULL AND NOT self_override
        AND (status != 'approved' OR approval_acknowledgement = 'I approve this exact payroll review revision for processing.')
      END) IS TRUE
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Payroll override evidence and retained approval requirements must be preserved"
  end

  private

  def replace_check(suffix, expression)
    name = "payroll_review_packages_#{suffix}"
    remove_check_constraint :payroll_review_packages, name: name
    add_check_constraint :payroll_review_packages, expression, name: name, validate: false
  end
end
