# Inactive worker reactivation acceptance — November 16, 2026

Scope: agent-executed affected-flow QA for `fix/reactivate-inactive-workers`, based on
`origin/main` `9f3ed93e9253e6f443655ca0638f0773f250d929`. Tested the implementation
committed with this record. No production access, merge, or deployment was performed.

Cornerstone staff manage client payroll using employee profiles, MoSa Revel hours,
and optional change workbooks. Returning imported inactive workers must not require
a false termination. Managers/admins retain transition authority; accountants get
guidance and clients retain their existing portal behavior. Sources: the task's
November 16 incident report, [README](../../README.md),
[staff policy](../../api/app/policies/staff_role_policy.rb), and
[MoSa import service](../../api/app/services/payroll_import/import_service.rb).
The employee list already supports Inactive filtering; reactivation lives in the
profile editor. Existing employee serialization and `audit_actions` already expose
status history and audit successful reactivation requests.

## Browser acceptance

Local synthetic fixtures only: isolated test database `payroll_reactivate_01a1e37c_test`,
Rails test on 127.0.0.1:3196, Vite on 127.0.0.1:5196, desktop Chromium at 1280×800.
Company 218 and workers 166/167 belonged to this disposable fixture. Admin was an
organization admin; accountant had an explicit company assignment. Frontend used
the local auth bypass, with actual API role/capability responses and authorization.

| Case | Actions and expected saved result | Result |
| --- | --- | --- |
| B1 Admin return | Open inactive profile, choose Reactivate, confirm today's effective date. Reload activity; expect Active and a reactivated/inactive-to-active milestone. | passed; SQL confirmed active with no termination date, one reactivated event, and employees#reactivate audit |
| B2 Accountant | Open another inactive profile as accountant. Expect manager/admin hint and no Reactivate button; worker remains inactive. | passed |

Evidence is local and private under
`~/Desktop/ShimizuTechnology/output/payroll-reactivate-inactive-20261116/` (directory mode 700):
`admin-inactive.png`, `admin-status-history.png`, `accountant-inactive.png`.
Required browser cases: 2 passed, 0 failed, 0 blocked, 0 not run.
Mobile, native devices, and the real import upload UI were not exercised in this
bounded browser pass. Import guidance/link and re-upload behavior have automated
coverage below; this is not a comprehensive payroll acceptance run.

## Automated checks

- Targeted RSpec: 35 examples, 0 failures across transition service, employee
  eligibility, MoSa adapter, preview replacement/idempotency, and affected employee
  requests. Includes inactive and terminated return, active refusal, accountant
  refusal, client endpoint exclusion, serializer/history, audit metadata, eligible
  pay periods, workbook IDs/names, and company-scoped unmatched guidance.
- Re-upload regression: preview original unmatched PDF, reactivate worker, upload
  identical bytes, require explicit replacement confirmation/reason, retain the
  original review, match the active worker in revision 2, and deduplicate retry.
  MoSa preview fingerprints include active employee IDs because source bytes alone
  cannot identify matching results after a worker returns.
- Affected Vitest: 76 tests passed in six files (status banner, dialog, retained
  rates, import payroll impact, portal import, owner pay).
- Full RuboCop: 1,844 files inspected, no offenses.
- Brakeman: no errors or security warnings.
- Web ESLint, `tsc --noEmit`, and `tsc -b`: passed.
- Impeccable 4.6.0 on EmployeeForm, EmployeeStatusTransitionDialog and ImportModal:
  no findings (`[]`), telemetry disabled. This advisory scan does not replace QA.

Initial regression development exposed an unassociated effective-date label;
connecting the label and input fixed it, and the dialog interaction test passed.
Full local RSpec/Vitest and CI browser suites were deliberately not run because
machine load was high. GitHub's required backend/frontend/browser checks and
CodeRabbit review remain separate PR gates.

## Resource disposition

The task-owned preview tab was closed and Rails/Vite processes were stopped.
The isolated database and bundle directory are deleted before task handback.
Shared PostgreSQL, Redis, existing simulators, and other baseline resources remain
untouched. The requested worktree remains in place; the PR is held for the lead.
