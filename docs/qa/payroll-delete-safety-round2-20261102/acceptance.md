# PR417 round 2 — 2026-11-02

Held for the November 7 release; do not merge. No staging or production access or deployment. Final application/test source: `29cc2b36bcca4afbfeb70b548d1d0f947d522e28`. The evidence commit preserves its API and frontend trees.

Cornerstone serves Dafne, Chels and accountants preparing Guam payroll. This round covers retained client review evidence, typed hours during scope changes, and readable/reconciled check stubs. Sources: PR417 and its inline comments, the previous acceptance/handoff, current implementation, and Brain Dump `work/shimizu-tech/Cornerstone/payroll-aire-qa-findings-2026-10-14.md`.

The migration already retained unknown legacy history at `36d685ce`: every old package starts with `client_review_history_unknown=true`; a positive sharing stamp may replace that marker. Only new issuer-created packages explicitly establish known unshared history. The strengthened down/up regression proves that approval-now-off historical packages refuse deletion with every company/run/item/package attribute unchanged, while a fresh never-shared run/item/package deletes. Superseded, never-visible new revisions remain deletable. No production history, including Kasperbauer's calculated runs, was touched.

Scope changes check staged payroll edits before changing context, local storage or API headers. Round 2 also fixes accepted switches: the old route could undo a new company during AppFeedback's keyed remount. A scope reservation now lasts for the originating location key until its redirect commits. New navigation keys retain normal route synchronization. Real controls/remount tests failed before this repair and passed afterward.

Agent-executed affected-flow acceptance used synthetic data and local Chromium. T3 snapshots failed twice with `Preview automation snapshot timed out after 15000ms.` Its owned tab was closed/released before the fallback.

| Case | Expected result and evidence | Result |
| --- | --- | --- |
| M1 | Migration down/up; unknown historical review retained without writes; fresh known-unshared run/package/items removed. Migration/revision suite: 12 examples. | Passed |
| N3 | Type 17 hours; client/org Stay keeps hours, route, scope and stored scope; Leave switches once and retains the destination. Real controls and keyed route remount. | Passed at 1440×900 and 390×844 |
| P1 | Six default/saved-profile before/after PDF pairs, plus an empty-header regression; all deduction rows readable, summary contained and NET PAY inside both stub sections. Actual app check/statement previews and downloads. | Passed at both browser widths; rendered PDFs visually inspected |
| P2 | Old prepared-summary digest rejected with HTTP409 before storage download, with $0 and $20 non-taxable pay; confirmed stored PDF bytes remain downloadable unchanged. | Both request regressions passed |

`ui-results.json` and scope screenshots record N3. `desktop-org-leave-before-fix.png` retains the observed accepted-switch failure. Mobile automation initially selected a hidden desktop organization control; the visible mobile control then passed. `pdf-ui-results.json` records final-source fresh-server previews. `ui-single-statement.pdf`, `ui-batch-statements.pdf` and `ui-check-preview.pdf` are final downloaded responses. Browser resizing does not certify physical-phone keyboards or printer alignment.

`profile-renders.json` records stock/configuration fixtures, hashes and expected amounts. Each uses 10 hours × $10 = $100 gross, $20 outside gross and $12.65 tax; each deduction is $1. Before uses renderer `36d685ce`; the six after pairs use the repaired renderer from `c394ef15`. The later empty-header change does not change their drawing paths. Every PDF is one page. Poppler PNGs were visually inspected, and both current/YTD summaries reconcile.

| Fixture | Before | After |
| --- | --- | --- |
| Default bottom stock | before-default-bottom.pdf | after-default-bottom.pdf |
| Default top stock | before-default-top.pdf | after-default-top.pdf |
| 95–108pt deductions | before-95-108pt.pdf | after-95-108pt.pdf |
| Ten deductions / compact fallback | before-many-deductions.pdf | after-many-deductions.pdf |
| Wrapped narrow saved profile | before-narrow-saved-profile.pdf | after-narrow-saved-profile.pdf |
| Saved top-stock coordinates/offset | before-saved-offset-profile.pdf | after-saved-offset-profile.pdf |
| Empty deductions in ~9.4pt | Previous 10pt guard refused | after-empty-deductions.pdf |

The summary height comes from the rendered table, including wrapped text. Deductions reserve that same height plus NET PAY and a gap. Prawn gets a small row-fit rounding allowance so the final summary row stays on the page. Table validation happens before entering its bounding box, preserving valid coordinates if the fallback runs.

The requested minimum normal-table scale remains 0.75. Below it, every deduction stays in a complete unscaled 6.5pt compact list. If even that list cannot fit, generation refuses with layout/earnings-statement guidance. A fifty-row regression verifies refusal. There is no detail attachment, omitted row or inserted check-stock page. The empty-section regression permits the measured header fit below the former arbitrary 10pt cutoff. Default check-face coordinates and saved settings are preserved.

Private production saved profiles and physical printers were not accessed. Verification covers stock defaults and explicit synthetic saved-profile configurations; it does not certify Dafne's or Chels's private physical calibration.

All engineering gates passed; exact source trees, shard coverage and log hashes are in `gate-results.json`:

| Gate | Result |
| --- | --- |
| Full RSpec | All 532 files; 5,816 examples; zero failures. Four disjoint shards: 1,507 + 1,674 + 1,226 + 1,409. Each had a unique database, TEST_STORAGE_ROOT and TMPDIR. |
| Transaction-mode PgBouncer | 13 examples, zero failures, including all four cases conditional in the ordinary full run. |
| Frontend | Typecheck, lint, all 143 files / 1,388 tests, production build passed. Four workers, 120s test/hook timeouts, one retry permitted; assertions unchanged. |
| RuboCop / Brakeman / bundler-audit | 1,597 files clean; zero security warnings; zero vulnerabilities. |
| Additional focused checks | Migration/revision 12; renderer/workflow/request 67; digest $0/$20 2; scope/guard 11: all passed. |
| Impeccable advisory | `[]` on changed context/route paths. |

Incomplete diagnostic runs are excluded from full coverage. Shared PostgreSQL and heavy workstation load caused severe delays; a controlled transaction benchmark measured ~8.6× better throughput on the owned disposable local PostgreSQL17 instance. The final complete RSpec gate ran there on exact source `29cc2b36`. Earlier default/30s frontend timeouts were retained as diagnostics; the isolated 84-test AIRE file and final complete suite passed. The initial local production build correctly refused missing deployment flags; the final build passed with matching production flags, without deployment or production access. The existing large-chunk advisory remains.

The full-review command was posted once at issuecomment-6565785966 and was rate-limited; no CodeRabbit approval is claimed. All eight original inline threads and two later minor threads received replies. The empty-header follow-up was fixed. The suggestion to change minimum scale to1.0 was not applied because the task explicitly requires0.75. Final CI/reviewer state and resource cleanup are reported in the PR description and local handoff.

Task-owned UI servers, Chromium processes and the T3 tab were cleaned after their QA phases. The final test databases and owned PostgreSQL/PgBouncer are tracked separately for exact cleanup before handback. Shared services, baseline tabs/devices and the original dirty checkout are preserved. The held branch/worktree remain available.
