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
- Local private storage; a controlled synthetic scanner returns clean. Production
  malware scanning, Clerk, Cable delivery and remote R2 are not certified here.
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
unscanned/pending/infected/error files, tenant/period isolation, retry deduplication,
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

## Serial engineering gates

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

## Rollout and retention

New uploads currently use `ClientDocumentScanner::Noop`, whose initial state is
`not_scanned`. The bridge intentionally requires `clean` and the configured
scanner's intake permission. A working scanner/clean-result path is a rollout
dependency; this PR does not claim to supply or verify it.

The new migration only adds a provenance table and nullable intake-document FK.
Source revision/file retention stays independent of intake storage ownership.
The provenance table restricts deleting linked import records. No merge,
deployment, live data change or email send was performed by the implementation
agent. Exact local cleanup and final gate results are recorded in the handoff.

Local evidence: `output/payroll-portal-pr6-20261113/` under the Shimizu Technology
root contains desktop/phone review and Imported screenshots, source-hash and
saved-payroll `outcomes.json`, reproducible synthetic fixture scripts and the
handoff.
