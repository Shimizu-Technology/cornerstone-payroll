# PR 6b — client pay stubs

## Context and acceptance
2026-11-14; stacked on 6a t3/client-reports (064d572e).
Sources: PR 6a QA ledger, PayPeriod.client_finished, staff PayStubsController,
PayStubGenerator, ClientPayPeriodDetail and ClientEmployeeOverview.
Agent-executed affected-flow QA; synthetic fixtures only.

Required: current-company finished payroll only; copied baseline allowed;
unfinished runs and archived practice access refused. Per-employee controls on
pay-period detail and employee history must view/download the same fresh PDF.
Every generated client PDF is audited with actor, employee and period. No check
images, year-end forms, stored-PDF access or production changes.

## Implementation and statement contents
Client endpoints call the existing PayStubGenerator directly. They never read or
write R2 artifacts, so older stored statements with accountant warnings cannot
be served. Source review found company/employee information, earnings, employee
taxes/deductions, employer contributions, payment details and current/YTD totals.
The current generator contains no accountant review-warning output or transmittal
notes. The original implementation supplied a client-specific finished YTD scope.
The fix round below removes that behavior to match the staff statement.

Downloads record AuditLog before sending; failure to write the audit prevents
delivery. Responses use private, no-store. Viewing fetches the same audited PDF
and uses the existing PDF preview, which can also download/print that fetched copy.

## Automated evidence
Mac mini:
- npm run lint and npx tsc -b passed.
- Affected Vitest: 3 files / 5 tests passed, --maxWorkers=2. Includes profile
  regression, stub empty state, preview and failed-read recovery.
- Full RuboCop: 1820 files, no offenses; new spec also rechecked after edits.
- Brakeman 8.0.6: no warnings, no errors.
- Impeccable advisory scan: [].
- Public Chromium combined reports/stub specs: 4 passed at 1440/390.
- Additional final stub browser run: 2 passed at 1440/390. Verified PDF canvas
  rendering with a valid synthetic PDF, closing preview, download from period
  detail, navigation to employee history, download there, and no horizontal
  page overflow. Mocked transport; does not establish real API authorization.

ASUS:
- Targeted stub specs and full backend suite attempted separately.
- Both blocked before sync: ci@127.0.0.1: Permission denied (publickey).
- Database-backed request specs remain NOT RUN: foreign company/employee,
  draft/calculated/approved exclusion, copied baseline and archived copy,
  audit metadata/repeated reads, statement privacy, and YTD draft exclusion.
- Existing backend generator/model regression suites also require CI/ASUS.
- No actual devices, native touch/keyboard or real API browser integration run.

## Cleanup and handoff
Playwright stopped its owned Vite/browser children after each run. No database,
Docker container or simulator started. T3's baseline listener remains untouched.
Lifecycle helper is blocked by the shared machine-profile schema error recorded
in the 6a ledger; processes were tracked manually. No runtime resource is handed
off. Source branch and clone stay available for the lead; no merge or deployment.

Backend acceptance and independent review remain required. Open as a draft
against t3/client-reports until 6a merges, then retarget main and rerun affected
checks. Lead owns CodeRabbit/independent review, merge and deployment.

Final cleanup audit found other sessions' Vite servers on 6531/6532 and a local
Postgres process not started by this task. Ownership was verified from command
paths; all were left untouched. No task-owned listener or browser process remains.

## Fix-round plan — 2026-11-15
Original head dcf8a738; rebased onto #458 fix 65bc8875. Agent-executed
required affected-flow cases: S1 valid practice lineage and baseline/archive
boundary; S2 history, download and period controls all reject statements with
no earnings activity; S3 document_access audit before delivery, repeated reads;
S4 identical extracted client/staff PDF text with divergent stored YTD fixture,
and unchanged payroll-item/period attributes after generation; S5 period and
employee-history preview/download at 1440/390. Synthetic isolated fixtures only.

Clients now call the same unmodified PayStubGenerator as staff. Client-specific
YTD overrides in the generator, Employee and breakdown services are removed.
Stored net/tax YTD and the staff generator's existing earnings-breakdown rules
therefore match. A read still only creates its document audit, never saves
payroll data. Browser transport is mocked; native devices and real API browser
integration remain not_run. Backend cases will run on ASUS when its lock clears.

Fix-round local results (2026-11-15, combined stack):
- Lint and tsc -b passed. Affected Vitest: 3 files / 7 tests passed,
  maxWorkers=1 (report catalog, stub preview/recovery, employee overview).
- Public bundled Chromium: 6 passed, one worker at 1440/390. Both statement
  entry points download; preview renders a PDF canvas and closes; report catalog
  and employee-list recovery still work with no horizontal page overflow.
- Full RuboCop: 1837 files, no offenses. Brakeman: 0 errors, 0 warnings.
- ASUS remains pending: repeated exit 75 (another run owns its lock), plus one
  interrupted SSH/rsync connection. Backend acceptance has not been claimed.
- CodeRabbit has no inline threads; its general comment skipped the stacked
  base. A skipped success status does not establish review of these changes.
- Playwright cleaned its Vite/browser children. No simulators, local database
  or containers started. Remaining runner cleanup will be verified below.
