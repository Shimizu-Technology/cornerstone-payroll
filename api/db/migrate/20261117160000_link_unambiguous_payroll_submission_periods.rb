# frozen_string_literal: true

class LinkUnambiguousPayrollSubmissionPeriods < ActiveRecord::Migration[8.1]
  def up
    # SQL only: independent of future model callbacks and safe with no rows.
    # Preserve explicit links and leave ambiguous dates for staff to resolve.
    execute <<~SQL
      WITH candidates AS (
        SELECT files.id AS files_id, MIN(runs.id) AS run_id
        FROM payroll_submission_periods files
        JOIN pay_periods runs ON runs.company_id = files.company_id
          AND runs.start_date = files.start_date AND runs.end_date = files.end_date
          AND runs.cycle = 'regular' AND runs.run_purpose = 'regular'
          AND runs.correction_status IS NULL AND runs.test_workspace_role IS NULL
        WHERE files.pay_period_id IS NULL
        GROUP BY files.id HAVING COUNT(*) = 1
      )
      UPDATE payroll_submission_periods files
      SET pay_period_id = candidates.run_id
      FROM candidates WHERE files.id = candidates.files_id AND files.pay_period_id IS NULL
    SQL
  end

  def down
    # Links cannot be distinguished from staff selections; retain evidence.
  end
end
