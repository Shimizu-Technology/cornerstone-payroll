# Portal → MoSa import review acceptance (PR 6)

Core implementation: `6b73bde3ae8197ed525ab03f2e43d3f0863305f9`, based on main `6b629be7`.
A later link-only fix (`bafec364`) passes the period page's company explicitly to
staff evidence links because document snapshots omit company_id; a component
regression test verifies the destination without relying on document metadata.
Agent-executed affected-flow browser QA on November 12, 2026.

The requested bridge uses the existing MoSa parser, persisted server preview,
row dispositions, matching, overwrite, calculation, review-package and apply
controls. Structured portal instructions are displayed separately and remain
read-only. The client submission itself never changes payroll or employee data.

## Environment and fixtures

- Owned local Rails test database built with `db:schema:load`; no seeds.
- Actual React UI and Rails endpoints through a local Vite proxy. Synthetic
  client/staff identities use the existing test-only identity header.
- Initial QA used local private storage and a controlled synthetic scanner. The
  default-Noop correction rerun is recorded below. Clerk, Cable delivery and
  remote R2 are not certified here.
- Synthetic #433 Revel fixture: Avery Example, 40 regular hours, 2 overtime hours;
  source PDF gross deliberately differs from payroll. Employee master rate $10.
- Two ended periods: October 5–18 and October 19–November 1, 2026. Each width uses
  its own period. Each submission requests a wage change to $99 as a checklist
  instruction, deliberately different from the authoritative profile rate.
- CSS viewports 1280×900 and 390×844. Phone resizing does not certify real phone
  keyboards, Safari, touch gestures or installed-app behavior.
- Email is disabled. All six email ledger entries are skipped.

## Required browser scenarios

| Case | UI actions and persisted outcomes | 1280 | 390 |
| --- | --- | --- | --- |
| Q1 Submit | Client selects retained Revel fixture, adds the wage instruction, sends; revision 1 appears at its saved URL. Before staff apply: no payroll items. | passed | passed |
| Q2 Acknowledge and review | Staff confirm receipt, click Open in import review. Existing ImportModal opens directly at review with exact employee match, 40+2 OT, profile rate $10, and the $99 instruction alongside it. The checklist contains no editable inputs. Original and independent intake bytes have matching SHA-256 values and different storage keys. | passed | passed |
| Q3 Apply and confirm | Staff review the included employee and apply. Success appears. Client reload shows Imported revision 1. SQL: each saved paycheck has 40 regular hours, 2 overtime, $10 rate, $430 gross, $397.10 net. Employee rate remains $10. Each period has submit/acknowledge/import history, one import Activity entry and one imported notification event. Both source copies remain present. | passed | passed |

The desktop review uses the existing table; the phone review uses the existing
employee cards. No horizontal page or dialog overflow was found: widths remain
1280/1280 and 390/390. On the phone, scrolling the modal reaches Apply without
leaving the page. The source link and staff import link preserve period context.

Required browser acceptance: **3 passed, 0 failed, 0 blocked, 0 not run**, with all
six required viewport dimensions passed.

## Automated edge cases and limits

The focused suite covers full-period date mismatch, exactly 8 MiB and one byte
over, missing/duplicate roles, supporting attachments, changed retained bytes,
Noop not_scanned files, pending/infected/error refusal, enforcing-adapter
policy, tenant/period isolation, retry deduplication,
identical-file reuse across revisions, superseded selection with audited reason,
a newer revision before apply, approved/committed runs, pending-source
calculation/approval/commit gates, explicit source disposition, stale calculation,
unmatched employees, double apply, rollback and preview-copy cleanup on audit
failure, plus generic-intake bypass prevention. Existing #433 and lifecycle tests
are included. A real PostgreSQL contention test proves a correction waits on the
bridge's company/run locks and remains pending afterward. Remote-download unit
tests enforce the body bound even if the object grows after HEAD.

An additional correction-during-open-review browser scenario (Q4 in the initial
local planning ledger) was not run; that optional interaction is covered by the
request and PostgreSQL concurrency tests. Real production files, payroll cutover
reconciliation, approval/commit of live payroll and real email delivery are
outside this task.

## Initial implementation engineering gates (head 944384ac)

- Focused backend: **106 examples, 0 failures**.
- Full RSpec: **6,615 examples, 0 failures, 4 pending**, in 18m04s. The four
  existing transaction-pooler cases require TRANSACTION_POOLER_URL and
  TRANSACTION_POOLER_DIRECT_URL; no local pooler was started.
- RuboCop: **1,798 files, no offenses**. One final test whitespace correction.
- Brakeman: **0 errors, 0 security warnings**.
- Migration 20261113090000 down then up: **passed**, followed by **db:integrity
  passed**. Unrelated PostgreSQL schema dump formatting was preserved.
- Frontend `npm test -- --maxWorkers=1`: **166 files / 1,673 tests passed**.
- The final evidence-link fixture received its required `superseded: false`
  field after the strict build caught the omission; its **5 component tests
  passed** again. This changed fixture typing only.
- Typecheck, lint and strict TypeScript/Vite build: **passed**. Build uses
  `DEPLOYMENT_ENV=production VITE_DEPLOYMENT_ENV=production`, as CI requires.
  Existing large-chunk build warnings remain advisory.
- Impeccable 4.6.0 advisory scan: **no findings** across the four changed UI files.

## Shared safety policy and retention

Uses the portal's shared intake safety gate (no scanner configured per Leon's Nov 12 decision; infected/error/pending always blocked).

The bridge calls `document.ensure_usable_for!(:intake)`. No scan status is
hard-coded in the bridge. An enforcing adapter can require clean files through
the same shared gate. Checksum, byte-size, visibility, tenant, revision,
review/apply and retention gates remain unchanged.

The new migration only adds a provenance table and nullable intake-document FK.
Source revision/file retention stays independent of intake storage ownership.
The provenance table restricts deleting linked import records. No merge,
deployment, live data change or email send was performed by the implementation
agent. Exact local cleanup and final gate results are recorded in the handoff.

Local evidence: `output/payroll-portal-pr6-20261113/` under the Shimizu Technology
root contains desktop/phone review and Imported screenshots, source-hash and
saved-payroll `outcomes.json`, reproducible synthetic fixture scripts and the
handoff.

## Default-Noop correction acceptance (lead instruction, November 12)

The core 1280×900 browser flow was rerun using the unmodified default
ClientDocumentScanner::Noop: synthetic client submits a Revel PDF, staff
acknowledge, open the existing import review and apply, then the client reloads
and sees Imported. SQL confirms the retained portal document is not_scanned;
no scanner override was loaded. Original/intake bytes and snapshot hashes match,
with independent storage keys. The saved outcome is 40 regular/2 OT hours,
profile $10, gross $430 and net $397.10. One Activity/import notification event
was recorded; all three email deliveries are skipped.

The 390×844 check inspected the review's employee card and the client Imported
status. Page width stayed 390; dialog client/scroll width stayed 358. Both
required correction scenarios passed. No frontend source files changed in this
correction, so the conditional frontend gates were not rerun.

The focused regression suite additionally imports not_scanned PDF/workbook
sources under Noop, refuses infected/error/pending before parsing, and tests an
enforcing adapter that rejects all non-clean statuses while allowing clean.
The final correction gate counts are recorded in the handoff.

Correction gates at code commit 7f59191e: **66 focused examples, 0 failures**;
**6,620 full-suite examples, 0 failures, 4 existing pooler cases pending**;
**RuboCop 1,798 files clean**; **Brakeman 0 errors / 0 warnings**. The owned
schema-loaded correction DB, QA servers/tab, temporary storage and task-created
node_modules were cleaned. No merge, deployment or reviewer command was issued.

## Round 2 review corrections (November 13)

Code commit `77b4cbf95de945985da4c02070ec8d06fa746e5d` addresses all 11
verified first-review findings. Linked pending evidence is found by run ID even
after date edits; duplicate regular runs cannot escape same-date pending source
review. An unlinked period can be claimed only by the catalog's eligible regular
run under the existing locks. Source dispositions require the addressed linked
run, and import writes revalidate staff access after company/run locking.

Import and disposition preserve the client draft/approval/payment status.
`EVENTS` now declares that explicitly, and both controller actions use the model
transition recorder. Regressions retain `draft_ready`, `approved` and `paid`,
including status-change time/actor, with matching history from/to statuses.
Payroll approval, commit, stale selection and rollback gates remain intact.
Reopened reviews identify newer revisions; evidence links retain the explicit
company workspace; superseded-source and disposition reasons stay independent.

CI on the starting head `01c29662` had completed successfully (Quality run
43223890854, backend/frontend/browser passed). Its CodeRabbit check was rate
limited, which does not establish review coverage. The new-head CI/review remains
lead-owned after push; no reviewer commands, merge or deployment are authorized.

Serial local gates on an owned `db:schema:load` database:

- Focused backend: **235 examples, 0 failures**.
- Full backend: **6,635 examples, 0 failures, 4 existing transaction-pooler
  cases pending**, 17m20s. Local pooler URLs were not configured.
- RuboCop: **1,798 files, no offenses**. Brakeman: **0 errors / 0 warnings**.
- `npm ci`: passed, audit 0 vulnerabilities. Single-worker frontend tests:
  **167 files / 1,676 tests passed**. Typecheck and lint passed.
- Production-configured build passed with `DEPLOYMENT_ENV=production
  VITE_DEPLOYMENT_ENV=production`; existing large-chunk advisory only.
- Impeccable 4.6.0 returned `[]` for each of the four changed UI files.

Required agent-executed browser acceptance: **2 passed, 0 failed/blocked/not
run**. At 1280×900, a synthetic client sent revision 1 with a Revel PDF and $99
wage checklist; staff acknowledged, opened retained import review, reviewed and
applied; the client reload displayed **Imported revision 1**. Before apply there
were zero payroll items. The default Noop left the file `not_scanned`. The
390×844 check verified the read-only checklist, retained company link, employee
card and client Imported status. Page/dialog fit their widths; the review uses
vertical scrolling on the phone. No physical-phone or Safari acceptance is
claimed.

T3 preview completed submission/acknowledgment/initial review. Repeated screenshot
attempts returned `Preview automation snapshot timed out after 15000ms`, so QA
continued in a task-owned native Chrome tab (CUA browser host was unavailable).
Reopening reused the retained preview; apply occurred once at 1280. DevTools
responsive controls confirmed exact dimensions; exported screenshots have 2×
pixel dimensions. All task tabs and the owned DevTools window were closed.

Saved outcome: 40 regular + 2 OT, profile $10, gross $430, net $397.10; employee
master remains $10. Original/snapshot/intake hashes match with independent keys.
One import Activity/notification and three skipped email deliveries were saved.
The portal status stays Received while displaying Imported evidence. Evidence,
logs and review resolution records are in `output/payroll-portal-pr6-20261113/round2/`.
No schema/migration changes were made in this correction; PR #451 integration
and any rebase remain lead-owned.
