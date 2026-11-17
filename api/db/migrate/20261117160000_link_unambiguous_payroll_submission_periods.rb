# frozen_string_literal: true

class LinkUnambiguousPayrollSubmissionPeriods < ActiveRecord::Migration[8.1]
  def up
    # SQL only: independent of future model callbacks and safe with no rows.
    # Preserve active links; recover voided links only with one free replacement.
    execute <<~SQL
      WITH candidates AS (
        SELECT files.id AS files_id, MIN(runs.id) AS run_id
        FROM payroll_submission_periods files
        LEFT JOIN pay_periods previous ON previous.id = files.pay_period_id
        JOIN pay_periods runs ON runs.company_id = files.company_id
          AND runs.start_date = files.start_date AND runs.end_date = files.end_date
          AND runs.cycle = 'regular' AND runs.run_purpose = 'regular'
          AND runs.correction_status IS NULL AND runs.test_workspace_role IS NULL
          AND runs.parallel_run = FALSE
          AND NOT EXISTS (
            SELECT 1 FROM payroll_submission_periods taken WHERE taken.pay_period_id = runs.id
          )
        WHERE files.pay_period_id IS NULL OR previous.correction_status = 'voided'
        GROUP BY files.id HAVING COUNT(*) = 1
      )
      UPDATE payroll_submission_periods files
      SET pay_period_id = candidates.run_id
      FROM candidates WHERE files.id = candidates.files_id
    SQL
  end

  def down
    # Links cannot be distinguished from staff selections; retain evidence.
  end
end
