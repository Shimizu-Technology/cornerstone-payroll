# PR 6a — client reports

## Context and acceptance
2026-11-14; starting source: origin/main de4b62ca. Agent-executed affected-flow QA.
Cornerstone client staff need self-service reports for their current company.
Sources: docs/CLIENT_PORTAL_AND_GUAM_COMPLIANCE_PLAN_2026-04-25.md,
docs/PRACTICE_COPIES.md, client/staff report controllers, PayPeriod.client_finished.
No production access or deployment was performed.

Required: every listed report stays company-scoped; native payroll includes only
client_finished (committed plus copied baselines), including YTD/annual and tax
lookbacks. Staff defaults remain unchanged. Quarterly workflow and filing gates
stay private. Catalog and exports must work at 1440 and 390 CSS pixels.

## Automated evidence
- Mac mini: npm ci; npm run lint; npx tsc -b; catalog Vitest with --maxWorkers=2: passed.
- Mac mini: full RuboCop, 1818 files: passed after correcting new spec spacing.
- Mac mini: Brakeman 8.0.6: no warnings, no errors.
- Mac mini: Impeccable advisory scan: [].
- ASUS targeted request specs and full RSpec: both blocked before code sync by
  SSH error: ci@127.0.0.1: Permission denied (publickey). No specs executed there.
- Added per-endpoint own/foreign company and baseline cases, unfinished-period
  cases, tax/annual/YTD totals, and an exact GET-only route allowlist guard.
  These database tests are unverified until ASUS/CI runs them.

## Browser acceptance
Mocked APIs only; synthetic practice-company fixture; Chromium, desktop mouse
and 390px responsive viewport. Native device, touch keyboard and real API
integration are not tested. Initial attempt blocked by missing Chromium; browser
installation retried in a task-specific cache to avoid another install's lock.
Final browser result is recorded below.

## Scope
Payroll Register, Summary by Pay Date, Summary by Employee, Annual Totals,
Tax Withholding, Employer Liability, Form 941, Quarterly Packet (Schedule B,
W-1, SWICA), Employee Pay History, Checks & Payments Register, Deductions &
Contributions, Retirement, Installment Loans. Existing dashboard retained.

Staff-only: check sign-off, transmittal, full print package, final-record exports,
W-2GU/1099-NEC filing outputs, filing workflow mutations and SWICA ASCII filing
export. These contain firm operations or filing outputs outside this scope.
Government PDFs remain preparation copies, not proof of filing.

## Environment and cleanup
No local database, containers or native simulators started. Bundle installed only
under ignored api/vendor/bundle. Lifecycle helper failed before baseline with
"Invalid machine profile: schema_version must be 1"; exact processes tracked
manually. Baseline listener: T3 PID 66066 on port 3774 (borrowed, untouched).
Playwright owns and stops its Vite server/browser children after each run.
Required backend acceptance remains blocked; lead review and CI are still gates.

Final browser result: 2 passed (1440/390), including catalog visibility, finished
period selection, PDF download event and no horizontal page overflow. Corrected
the initial spec's nonexistent /companies/12/reports URL to the app's /reports.
Run used Chromium channel from task cache. Final controller metadata adjustment
also passed targeted RuboCop. No task-owned listeners remain after the run.
