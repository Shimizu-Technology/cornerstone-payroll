# Payroll deletion safety — 2026-11-02

Base: staging-v2 `ba027a743302fd79060eeb2cd0930c3e82cd1638`. Target: one held PR to staging-v2 for the November 7 release. Target refreshed to `f7c3525f0de23f4a97d96d2a5af01fb6f44c8927` (documentation-only PR414); merged locally without any application source changes. No staging or production access.

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

P1: downloaded single and batch PDFs, opened actual previews at both widths, rendered with Poppler and visually inspected. Both the plain-paper summary and both check-stub copies show $100 + $20 − $12.65 − $0 = $107.35 without overlap. The check-stub current and YTD columns agree. Initial UI/PDF source was `6b3cdac3286608ab01633724778c5726711d32d5`. Review fixes were subsequently retested on `9a18ed42`; see the review retest below.

T3 preview was attempted first, then failed twice: “Preview automation snapshot timed out after 15000ms.” The task-created preview tab was closed and released. QA used local Playwright Chromium, 1440x900 and 390x844. The 390 run had scrollWidth 390. Synthetic committed-stub FICA bases and cached YTD amounts were completed during fixture preflight; its employee was kept separate from unfinished runs. No real provider authentication, payments or filing occurred.

## Initial automated gates (superseded by the final review gates)

- Focused final backend: 348 examples, zero failures; additional archived-stub regeneration suite: 20 examples, zero failures.
- Frontend full suite: 142 files, 1,379 tests passed. Typecheck/lint passed; production build passed (existing large-chunk advisory). New router tests exercise Back/sidebar/employee links, browser-history navigation, beforeunload and clean navigation.
- RuboCop: 1,596 files, no offenses. Brakeman: no warnings. bundler-audit: no vulnerabilities. npm ci audit: zero vulnerabilities.
- Transaction-mode PgBouncer: 13 examples passed, including the four conditional pooler cases.
- Impeccable advisory on changed UI paths: [].
- Complete final RSpec: all 531 files in four disjoint shards; 5,798 examples, zero failures. The four pooler-conditional pending cases were separately executed in the passing 13-example PgBouncer run. Each shard used its own `payroll_codex_del_finalN` database, `TEST_STORAGE_ROOT` and TMPDIR. Shard counts: 1,672 + 1,231 + 1,408 + 1,487. Gate evidence and exact tested api/web tree IDs: gate-results.json, verified at `537ed02fac5879f5fc58bbde48403ceb7c89476d`. Final subsequent changes are evidence only.
- The initial run found an existing model test expecting the late DeleteRestrictionError. The new pre-check correctly refuses first with RecordNotDestroyed. Its expectation was corrected while retaining every preservation assertion; the entire final suite was then rerun successfully. The dedicated late-callback request test still verifies transactional rollback independently of the pre-check.

## Initial resource cleanup

Lifecycle session `01a198f5-1edb-75e2-a4e7-e1a4247720e5`. Borrowed listeners, shared PostgreSQL 5432/Redis and existing simulators remain untouched. Disposable PostgreSQL 17 directory `/tmp/payroll-del-pg-01a198f5`, port 55447; helper refuses postgres claims by broad profile rule, so exact ownership is recorded in `/tmp/payroll-del-resource-ownership.txt` for manual cleanup. All nine task databases (focus, UI, pooler, original two shards, final four shards) were dropped. The exact disposable cluster was stopped with pg_ctl, then its directory and the individual storage/TMPDIR roots were removed. Rails 5347, Vite 4347, Chromium/browser nodes, T3 tab and PgBouncer 56447 are stopped/closed; all four owned listener ports are absent. `dev-lifecycle status` reports no active owned resources. No resource handoff or unresolved ownership. The worktree/branch remain available for held PR417; no merge or deployment occurred.

## Review fixes and final acceptance retest

Final runtime source: `9a18ed42`. CodeRabbit's first automatic review covered `1664bccd`; its material findings were fixed. The one manual `@coderabbitai review` request is [6564479359](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/417#issuecomment-6564479359); its [rate-limit reply](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/417#issuecomment-6564482904) is not approval. No duplicate request was posted.

Review strengthened the deletion pre-check to retain paid, printed or prepared nonemployee checks. Revision issuance and its intake/import callers acquire Company before PayPeriod and read the locked approval setting. The migration keeps legacy review sharing history unknown unless visibility is proved; these older runs are retained with plain guidance. New genuinely unshared automatic reviews are deletable. A PostgreSQL company-setting trigger records visible current reviews before approval is disabled or when enabled, including writes from older application processes during rollout. The versioned integrity snapshot restores the trigger after schema load. Superseded draft revisions are not stamped as published. Unknown legacy reviews remain protected after recovery; recalculation cannot prove their past visibility.

Company/organization switches now ask before changing context or API headers. Consent expires after the current navigation operation, so accepting Reports does not disable protection for later edits. Immediate route/scope synchronization reuses the same answer. A regression covers both the second edit and repeated scope checks followed by expiry.

Agent-executed local Chromium retest at 1440x900 and 390x844 passed N1/N2/N3/R1/P1. Evidence uses the `review-` prefix. N1 calculated 10 hours and deleted with 204. Refused N2 deletion returned 422, then reopened with 10 saved hours. Full run/item/earning/field/review/import JSON was byte-for-byte identical at both widths; hashes and collection counts are in `review-refused-delete-evidence.json`.

N3 Cancel preserved 17 hours through Back, sidebar Employees, company and organization changes. After accepting Reports and returning to Payroll, a new 19-hour edit remained protected. Company Leave prompted once. Native browser Back also warned and retained 23 hours after Cancel. R1 rebuilt 12 hours and a $25 bonus ($145 gross, $133.91 net), then retained them on reload. Phone scrollWidth was 390.

Single and batch earnings statements were downloaded again and actual PDF previews opened at both widths. Their current summary reconciles $100 + $20 − $12.65 − $0 = $107.35. Poppler renders were visually inspected. The tall check PDF has nine $1 deductions; both current/YTD stub copies remain clear of the expanded summary and reconcile to $98.35. Table flow/scaling reserves space above SUMMARY and NET PAY. Archived affected non-taxable statements are regenerated for correctness; versioned cache reuse is deferred.

Independent read-only review found two material issues in `8be5580c` (persistent navigation consent and mixed-version publication), both fixed. The second review was clean at `a6a4c8ec`; a narrow review of subsequent consent changes was clean through `9a18ed42`. Reviews did not execute tests or UI; the acceptance and gate evidence is separate. No physical-device, printer, provider, payment, filing or deployment certification is claimed.

Final statement source: `e81a715121b4406adf904c821a2b28a506499490`. The plain-paper YTD summary now includes non-taxable pay, other deductions and any additional withholding. Prior eligible additional withholding plus the current paycheck is counted exactly once, including before commit. Both calculated and committed regressions reconcile $100 + $20 − $12.65 − $3 − $9 = $95.35; the ordinary one-page regression also passes. All 58 statement/retirement/request examples passed. Independent review found the pre-commit omission at `01a21d32`; the correction was reviewed clean at `e81a7151`.

Actual single/batch previews were repeated at both widths after the YTD rows and typography change. Final small spacing adjustments were then verified through fresh local HTTP single/batch responses (`final-single-stub.pdf`, `final-batch-stubs.pdf`), Poppler rendering and visual inspection. Both remain one page and reconcile current and YTD totals, without touching stored payroll. Earlier screenshots/PDFs remain as the review trail.

The complete frontend rerun passed all 143 files / 1,384 tests with one retry permitted. The first run had two Testing Library wait timeouts in unchanged employee-rate and AIRE-connection tests under heavy machine load; the 34-example employee-rate file also passed separately. No application changes were made to address those timing failures. Typecheck, lint and the production build passed on the unchanged final web tree.

## Final engineering gate and cleanup

Full final RSpec at `e81a7151`: all 532 spec files, 5,810 examples, zero failures. Four disjoint 133-file partitions returned exit 0: 1,503 + 1,672 + 1,226 + 1,409 examples. Each had a unique `payroll_codex_del_acceptN` database, `TEST_STORAGE_ROOT` and TMPDIR. The four conditional pooler cases were separately executed in the passing 13-example PgBouncer run. Exact source trees and results: `gate-results.json`. Earlier interrupted or pre-review runs are not counted as this final gate.

Frontend full 143 files / 1,384 tests, typecheck, lint and production build passed. RuboCop inspected 1,597 files with no offenses; Brakeman found no warnings; bundler-audit found no vulnerabilities. The final statement/request suite additionally passed 58 examples.

All task databases were dropped. The exact owned PostgreSQL17 instance (PID79362, port55447, `/tmp/payroll-del-review-pg-01a198f5`) was stopped and its directory removed after the gate completed. Task storage/TMPDIR roots were removed. Rails/Vite/Chromium/T3 tab/PgBouncer and test workers are stopped/closed. Ports4347/5347/55447/56447 are absent. `dev-lifecycle status` reports no active owned resources. Shared PostgreSQL5432 (PID5645), Redis6379 (PID5500) and protected services remain available. No runtime handoff or unresolved ownership. The branch/worktree remain for the held, unmerged PR417; no staging/production access or deployment occurred.
