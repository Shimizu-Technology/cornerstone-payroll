# Corrective component ledger — October 24, 2026

Owner: `payroll-impl-ledger`. Implementation source: `b11032c40fa91aabefe5e3337644eebe730e6ca6`, including staging-v2 #377 (`28b14349`). The lead owns merge and release. No staging/production access or historical data repair was performed.

Cornerstone's accountants process multi-client Guam payroll. A corrective supplemental must explain every change in pay, deductions and employer obligations without rewriting the original paycheck. Context and acceptance come from the independently verified A4/A2/A3 inventory in `output/payroll-aire-review-2026-10-24/v-payroll/REPORT.md`, `impl-rules.md`, and the Cornerstone September 19 priorities note in Brain Dump.

## Acceptance

Agent-executed affected-flow QA used only synthetic local data and a dedicated headless Chromium instance. Both 1280×800 and 390×844 fixtures started with $900 gross and a 5% flexible 401(k) contribution of $45. The agent opened the corrective modal, changed regular hours from 60 to 65, reviewed and issued the correction, then reloaded. The saved supplemental had $75 gross, $3.75 contribution and $58.38 net. Each employee's pay-date range report showed $48.75 retirement after reload.

The agent opened employee-summary and retirement report previews through their View controls. Each original report showed $45 and each supplemental showed $3.75; the eight actual UI-triggered PDF responses were extracted and checked. Native PDF iframes did not paint in headless Chromium, so their content was verified from the downloaded bytes and with Poppler. This does not establish native-device, physical-printing or operator acceptance.

The real full-print-package endpoint generated a seven-page negative corrective package. Its employee summary showed positive cash-effect credits for negative taxes and retirement deductions, while employer liability reductions retained their negative signs. Paycheck history now explicitly includes other pay in the gross/deduction/net reconciliation. All pages were rendered and inspected; the automated test verifies signed detail and zero formatting.

![Signed paycheck-history reconciliation](assets/payroll-ledger-negative-history.png)

![Retirement contribution saved on the supplemental](assets/payroll-ledger-retirement-delta.png)

## Automated checks

- The new regression matrix covers flexible deductions and employer contributions, all five payroll-field treatments, field mirrors/reporting groups, bonus, non-taxable cash, custom entries, signed hours, hourly rate changes, salary nonexempt rate changes, repeated targets, voiding either supplemental, stale previews/retries, immutable original components, W-2 D/AA, YTD and liability totals. Unsupported loan transitions, ambiguous component detail, custom-column changes and salary overtime-hour changes requiring daily coverage are held.
- Schema load and PostgreSQL integrity passed. RuboCop inspected 1,475 files with no offenses. Brakeman found no warnings. Bundler and npm audits found no vulnerabilities.
- Node 22.22.3 web gate passed: 121 files / 1,129 tests, typecheck, lint and production build. The initial Node 26 run is retained as a superseded harness-environment failure.
- Browser lanes passed: 131 public, 45 release, 10 refresh, 24 pay-item tests.
- Full backend results and review status are recorded in the final PR and local `RESULT.md`.

There are no migrations or historical backfills. Ordinary nonnegative input rules remain in place; signed field/hour/JSON validation requires a same-owner linked corrective supplemental. Unchanged scheduled loans retain their original identity and create no repayment delta or transaction. Changed loan components remain on hold because this change introduces no loan-ledger transition. Changed flexible employer insurance is also held: the legacy insurance aggregate cannot safely classify that employer liability.

Detailed logs, fixtures, actual PDFs and screenshots are retained in `/Users/leonshimizu/Desktop/ShimizuTechnology/output/payroll-aire-review-2026-10-24/impl/payroll-ledger/`. Browser contexts/processes and servers were stopped after QA. Dedicated UI/release/refresh/pay-item databases were dropped; the final backend database is removed after its run. The worktree and branch are retained for the lead.

The first full backend run completed 5,061 examples with three failures. The capped-field mirror failure was fixed by preserving the existing generated employee-field mirror identity even when its requested amount differs from the capped authoritative field. Two assertions were updated for the more specific component-reconciliation hold and the corrected other-pay note. Additional net-only cash and loan/insurance regressions passed (4 examples); the final backend run is recorded in the PR/result.
