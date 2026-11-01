# Payroll deletion safety — 2026-11-02

Base: staging-v2 `ba027a743302fd79060eeb2cd0930c3e82cd1638`. Target: one held PR to staging-v2 for the November 7 release. No staging or production access.

## Context and acceptance

Cornerstone Payroll is a Guam payroll workflow for Dafne (admin), Chels, and accountants Mark and Benjo. This repair covers calculating and deleting unfinished runs, retaining approval/payment history, entering hours without accidental loss, and reconciling employee statements. Rails API + React frontend; client-required review revisions are published in the portal when calculation issues a revision. There is no separate review-send endpoint or review-comment/decline model; existing client responses are stored as approval evidence/notes. General client-portal conversations are company-level records and remain untouched.

Sources: README.md; the supplied task; `docs/qa/payroll-ux-fixes-20261102/acceptance.md`; PR416 local handoffs; `QA_LEDGER.md`, Retest 2026-11-02 (ba027a74), and PDFs/text under `downloads/retest-ba027a74/` in the supplied external audit directory. Brain Dump `work/shimizu-tech/Cornerstone/payroll-aire-qa-findings-2026-10-14.md` establishes the accountant's review/approval, saved-outcome and report-reconciliation journeys. Deployment refs were checked through Git only: origin/staging-v2 ba027a74, origin/main 6c78c345. No deployment was inspected or changed.

Agent-executed affected-flow acceptance. Each scenario is required at 1440x900 and 390x844 in a local Chromium browser. Synthetic fixtures only. Physical-phone keyboards, printers, filing, payments, OAuth and AIRE transport are excluded.

| Case | Starting fixture and UI actions | Expected saved result | Desktop | 390 |
| --- | --- | --- | --- | --- |
| N1 | Never-approved draft; enter 10 hours, calculate, return to list, Delete, confirm | Run, paycheck and automatic review removed; no error | passed | passed |
| N2 | Populated calculated run with shared review; Delete, confirm, reopen/reload | Plain refusal; run, hours, earnings, field entries, review unchanged | passed | passed |
| R1 | Calculated run with zero items, representing #110; open Hours, Enter pay, re-enter verified hours/adjustments, calculate, reload | Rebuilt pay and hours persist; approval possible when valid | passed | passed |
| N3 | Draft; type hours; use Back and sidebar Employees; Cancel, then Leave; repeat with browser Back | Cancel preserves input and route; Leave navigates; no prompt after successful calculation | passed | passed |
| P1 | Employee with gross 100, non-taxable 20, taxes 12.65, deductions 0; open/download stub and batch | Summary shows 100 + 20 − 12.65 − 0 = 107.35; PDF legible | passed | passed |

## Root cause and regression evidence

The UI sends one DELETE and no reset/clear request. `with_financial_pay_period_lock` opens an outer transaction around `destroy`. Both the old explicit transaction (main) and `with_lock` (staging-v2) join it. Payroll-item dependent callbacks delete items and their earnings/field entries before `payroll_review_packages` aborts destruction. The action rescues `RecordNotDestroyed` and returns 422 *inside the outer transaction*. The exception never escapes that outer transaction, which commits the child deletes. No second connection or out-of-transaction delete is needed.

The populated request regression failed against ba027a74: 422 with the run/review still present, but item/earning/field entry all missing. Log: `/tmp/payroll-del-old-regression.log`. Source comparison confirms main 6c78c345 has the same outer transaction/action rescue and dependent ordering. The new `requires_new: true` savepoint rolls back before the rescue, and a prepend/model pre-check refuses protected runs before writes. An injected late callback failure exercises rollback independently of the pre-check.

## Recovery for a run already emptied, including staging #110

A recalculation cannot recreate lost manual hours or adjustments. Open the run → Hours → Enter pay for each employee → re-enter hours, bonus, non-taxable pay and other adjustments from the verified original timecards/source records → Calculate payroll → review saved pay and totals. Re-import an available original source package only after checking its contents. Do not infer missing hours from pay rates or a zero-item calculated status. The empty-run banner explains this path. An eligible never-approved run may alternatively be deleted and recreated after this repair. Previously approved/shared runs retain their evidence and must be corrected rather than deleted.

Local recovery passed in both dimensions: 12 regular hours × $10 plus a $25 bonus gave gross $145 and net $133.91; reload retained the inputs. N1 calculated at $100 gross/$92.35 net, then DELETE returned 204 and subsequent GET returned 404. N2 returned 422 with plain client-history guidance; run, item, earnings, field entries, review and import were byte-for-byte identical before/after in both dimensions (see refused-delete-evidence.json). N3 Cancel preserved 17 desktop/19 phone hours through Back and sidebar; Leave navigated. Actual browser Back also triggered the browser's native unsaved-page warning and retained 23 typed hours after Cancel at both widths. Clean navigation after successful calculation had no prompt.

P1: downloaded single and batch PDFs, opened actual previews at both widths, rendered with Poppler and visually inspected. Both the plain-paper summary and both check-stub copies show $100 + $20 − $12.65 − $0 = $107.35 without overlap. The check-stub current and YTD columns agree. Source commit for final UI/PDF verification: `6b3cdac3286608ab01633724778c5726711d32d5` (later evidence-only commits do not change source).

T3 preview was attempted first, then failed twice: “Preview automation snapshot timed out after 15000ms.” The task-created preview tab was closed and released. QA used local Playwright Chromium, 1440x900 and 390x844. The 390 run had scrollWidth 390. Synthetic committed-stub FICA bases and cached YTD amounts were completed during fixture preflight; its employee was kept separate from unfinished runs. No real provider authentication, payments or filing occurred.

## Automated gates

- Focused final backend: 348 examples, zero failures; additional archived-stub regeneration suite: 20 examples, zero failures.
- Frontend full suite: 142 files, 1,379 tests passed. Typecheck/lint passed; production build passed (existing large-chunk advisory). New router tests exercise Back/sidebar/employee links, browser-history navigation, beforeunload and clean navigation.
- RuboCop: 1,596 files, no offenses. Brakeman: no warnings. bundler-audit: no vulnerabilities. npm ci audit: zero vulnerabilities.
- Transaction-mode PgBouncer: 13 examples passed, including the four conditional pooler cases.
- Impeccable advisory on changed UI paths: [].
- Complete RSpec: all 531 files in disjoint manifests, unique databases and storage roots; running. Final result pending.

## Resource ownership

Lifecycle session `01a198f5-1edb-75e2-a4e7-e1a4247720e5`. Borrowed listeners, shared PostgreSQL 5432/Redis and existing simulators remain untouched. Disposable PostgreSQL 17 directory `/tmp/payroll-del-pg-01a198f5`, port 55447; helper refuses postgres claims by broad profile rule, so exact ownership is recorded in `/tmp/payroll-del-resource-ownership.txt` for manual cleanup. All databases use the `payroll_codex_del_` prefix; shards have separate storage and temporary directories. Final cleanup pending.
