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

## Fix-round plan — 2026-11-15
Starting head 064d572e, verified base main. Agent-executed affected-flow QA;
synthetic test records only. This round repairs client report privacy and
practice fixtures, finished-period selection, employee-list recovery and loan
opening balances. Sources: the independent review, current client/staff report
controllers and shared builders. The existing product brief above still applies.

Required cases: R1 own-company finished/baseline report routes and unfinished/
foreign rejection; R2 deposit notes, confirmation and receipt metadata absent
from client JSON/PDF/workbooks while staff defaults remain; R3 staff component
review warnings absent from client JSON/PDF; R4 period selector ignores newer
calculated/approved runs at 1440/390; R5 employee-list failure leaves other
reports usable and retry loads every employee page; R6 scoped loans without
transactions use opening balance. The Checks & Payments Register deliberately
retains voided/reversed checks, labelled voided, to preserve payment history.

Backend cases run on ASUS; frontend lint/TypeScript/Vitest and mocked public
Chromium journeys run on this MacBook. Real API browser integration, native
hardware, production records and deployment are outside this fix round.
Results are pending below; earlier blocked backend results are historical.

Fix-round frontend results (2026-11-15, working tree based on 064d572e):
- MacBook lint, tsc -b: passed. Vitest: 1 file / 3 tests, maxWorkers=1, passed.
- Public bundled Chromium: 4 passed, one worker; catalog/default selection,
  PDF download, employee-list failure/retry, and overflow checks at 1440/390.
  First run had 2 failures from a newly added incorrect filename expectation;
  corrected to the application's payroll_summary_by_employee.pdf and reran.
- Full RuboCop: 1835 files, no offenses. Brakeman: 0 errors, 0 warnings.
- Impeccable advisory scan: [].
- ASUS attempts returned 75 (another run active); no backend spec has run yet
  in this fix round. R1/R2/R3/R6 remain pending backend execution. R4/R5 passed.
- No inline CodeRabbit threads existed at inspection. #458's general comment
  says rate limited; that status is not an independent review of these fixes.
- Playwright terminated its Vite/browser children; lifecycle reports no active
  owned resources after that phase. Existing simulators/shared services untouched.

## Fix-round handback — backend blocked
Tested implementation: b3046e93; combined stub code: 5245b451. Final changes
below this point are documentation only. Agent-executed results above remain
valid for those source trees: 3 report Vitest tests / 4 report browser scenarios;
combined 7 Vitest tests / 6 browser scenarios. Full lint, TypeScript, RuboCop and
Brakeman passed locally. R4/R5 passed at 1440/390; R1/R2/R3/R6 are blocked, not
passed, pending the database-backed run. No backend examples executed on ASUS.

The runner repeatedly refused execution with exit 75 for over 20 minutes, with
several SSH banner/rsync interruptions (255). A read-only lock inspection found
another npm Playwright run holding the lock for over 33 minutes. Its processes
were left untouched. The task retry wrapper was stopped between attempts; no
remote tests or task-owned database/container had started. No full RSpec suite
was run. Native hardware and real API browser integration remain not_run.

No inline CodeRabbit threads existed to answer. Review was requested after the
fix push; CodeRabbit acknowledged #458's request, but no completed review of
the new head was available at handback. CI browser passed; backend/frontend CI
were still in progress at the last inspection. The PR remains draft.

Next action: rerun all required client request specs, all six admin report
request files, and touched service regressions on ASUS with TEST_DATABASE_URL
pointing to localhost:55432. The sibling PR ledger and local handoff retain the
exact command. Fix any failures, recheck the final heads and review threads,
and mark ready only after all required acceptance passes. Do not merge/deploy.

Cleanup: owned Playwright/Vite processes and retry wrapper ended; lifecycle
reports no active owned resources. Existing simulators and shared services were
preserved. Worktree and branches are retained for the lead; no runtime handoff.
