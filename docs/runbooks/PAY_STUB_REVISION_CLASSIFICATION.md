# Classify previously posted pay stub revisions

After the migration, open a Render shell for the payroll API in the target environment. Run the commands from the Rails application directory, `api/` in the repository. The shell needs access to the employee-document bucket and the system database scope.

1. Preview with `bundle exec rails employee_documents:classify_pay_stub_revisions`. Review the counts before applying. For the demo companies, expect at least 90 revisions with `same_figures` and zero `unresolved`.
2. Apply with `APPLY=1 bundle exec rails employee_documents:classify_pay_stub_revisions`. This caches figures from the original and later PDFs and updates the revision labels without sending notices or rewriting PDFs.
3. Run the preview again. Expect `label_changes=0`. Review any `unresolved` count for a missing predecessor, an unreadable PDF, or a storage error before retrying. The task keeps existing correction labels when the history is incomplete.

Re-running the task is safe.
