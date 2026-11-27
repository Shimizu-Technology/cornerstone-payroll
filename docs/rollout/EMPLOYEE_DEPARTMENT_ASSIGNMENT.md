# Assign departments from wage-rate labels

Check the company’s existing departments and count active employees without an assignment before running the task. If the existing assignments already cover the intended employees, skip the rollout. Map wage-rate labels to exact existing department names where possible.

Run from `api/` after the employee stub wage-label migration is deployed. Use the intended company's ID and approved exact labels. This example uses sample values.

```sh
COMPANY_ID=123 LABEL_MAP='Kitchen rate=Kitchen,Dining rate=Dining' bin/rails employee_organization:map_departments
```

The dry run prints counts only. Review the counts before repeating the command with `APPLY=true`. The task processes active employees and prefers an active primary wage rate with a mapped label. Otherwise it counts matching regular earning lines from committed, reportable, non-voided paychecks. It reports and skips ties across departments, missing label matches, and inactive destination departments. Use `OVERWRITE=false` (the default) to fill gaps only. The dry run counts existing assignments to a different department separately. Use `OVERWRITE=true` only when replacing those assignments is intentional.

The task creates active departments as needed and audits changed assignments. It reads wage rates and payroll earnings, and writes only departments, employee department IDs, and audit activity. The migration preserves the regular wage fallback label used for existing employee stub history. Changing a department after migration leaves the posted PDF and its fingerprint intact. Staff PDF re-renders may display the current department.

Refresh any outstanding History Approval review or Exact Line Correction preview affected by a roster change before confirming it.
