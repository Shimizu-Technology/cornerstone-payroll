# Classify previously posted pay stub revisions

After the migration, run these commands from `api/` in the target Rails environment with access to the employee-document bucket and the system database scope.

1. Preview with `bin/rails employee_documents:classify_pay_stub_revisions`. The task compares each payroll stub revision after the first with its linked predecessor and prints aggregate counts. Review `label_changes` and `unresolved` before applying.
2. Apply with `APPLY=1 bin/rails employee_documents:classify_pay_stub_revisions`. This updates revision classification without sending notices or rewriting PDFs.
3. Run the preview again. Expect `label_changes=0`. An `unresolved` count means a predecessor was missing or a frozen PDF could not be read or verified. Check the target storage configuration and document availability before retrying. Those revisions retain their existing classification.

`preserved` counts corrective paychecks and reinstatements whose existing labels are retained. Re-running the task is safe.
