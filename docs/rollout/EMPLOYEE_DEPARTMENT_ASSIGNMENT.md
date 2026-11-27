# Assign departments from wage-rate labels

From `api/`, run with the intended company's ID and approved exact labels. This example uses sample values.

```sh
COMPANY_ID=123 LABEL_MAP='Kitchen rate=Kitchen,Dining rate=Dining' bin/rails employee_organization:map_departments
```

The dry run prints counts only. Review the counts before repeating the same command with `APPLY=true`. The task prefers an active primary wage rate with a mapped label. Otherwise it counts matching regular earning lines for active mapped rates. Employees with a tie across departments or no mapped match keep their current assignment. The task creates departments as needed and audits changed assignments. It reads wage rates and payroll earnings and writes only departments, employee department assignments, and audit activity. Existing approved payroll history and posted PDFs stay intact. Refresh any outstanding history review affected by a roster change before approving it.
