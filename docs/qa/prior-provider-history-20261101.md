# Prior-provider history: implementation and acceptance

Base: staging-v2 d7170343 (2026-11-01). Held; no deployment or production/staging data access.

## Product and evidence

Cornerstone staff calculate, approve and commit genuinely unpaid Guam payroll; client managers configure onboarding and filing ownership. See README.md, the Kasperbauer audit at output/payroll-aire-prod-audit-2026-10-30/kasperbauer/REPORT.md (S1–S34), and Brain-Dump/work/shimizu-tech/Cornerstone/payroll-priorities-and-aire-reconciliation-2026-09-19.md. Historical payments must enter dated historical snapshots and opening balances, never native commitment or settlement. The existing QuickBooks clean-client contract remains available.

This screen extends Client Management in place. Accountants can read; client-configuration operators can reconcile, convert and activate. It inherits Cornerstone's neutral operational surfaces, primary actions, compact labels and responsive inputs. The five steps are select, reconcile, convert, review, activate. Inline validation preserves entries; saved state survives reload. No new animation: conversion and activation use busy controls and a settled status message. Phone verification is browser viewport coverage, not physical-device acceptance.

## Contract

One complete employer/year history, mapped to existing employees with source name and last-four identity checks. Retain provider evidence and operator-entered register totals per period; reconcile exact cents, including employer taxes and explicit FIT/SS/tip/uncapped Medicare bases. Calculations only prefill. Conversion retires sources atomically and retains their evidence. Activation locks snapshots, applies the normal opening bridge, and records quarterly/annual responsibility. No commitment service or outbound event is invoked. Reversal preserves audit/snapshots, removes inclusion and restores source runs before any live commitment; uncommitted downstream calculations must be discarded first to avoid stale context.

## Required acceptance ledger (agent executes, local synthetic fixtures)

| ID | Journey and expected saved outcome | Coverage | State |
|---|---|---|---|
| H01 | 3 salaried employees, 20 Jan 14–Oct 28 runs → reconciled 60 dated payments, source runs retired | backend + 1440 UI | passed (see execution below) |
| H02 | Register mismatch, stale preview, duplicate, overlapping/foreign employees rejected atomically | backend + recovery UI | passed (see execution below) |
| H03 | Activate: exact employee YTD, annual W-2/W-3 inputs, Q1–Q3 reference/external; Q4 October + live Nov | backend | passed (see execution below) |
| H04 | No historical instruments, obligations, deposits, loans, jobs/email; first live Nov calculates/approves normal FICA | backend | passed (see execution below) |
| H05 | Accountant reads; unauthorized mutations rejected; client context and revoked access fail closed | backend + UI | passed (see execution below) |
| H06 | Manual period entry uses identical money/identity/reconciliation rules | backend + 390 UI | passed (see execution below) |
| H07 | Reversal before live commitment removes history once and restores source evidence; post-commit reversal rejected | backend + UI | passed (see execution below) |
| H08 | Desktop/phone select → reconcile → convert → review → activate, reload, keyboard/error states | 1440/390 browser | passed (see execution below) |

Full backend and frontend gates, migration up/down, db integrity, dependency audits, Impeccable advisory and public browser suite are recorded separately. Production registers, employee documents, deposit schedules, Q1–Q3 returns/receipts and October deposit reconciliation remain operator prerequisites. No actual filing, payment or external transport is in scope.

## Execution evidence

Agent-executed, synthetic local PostgreSQL, API 4137 and Vite 5177; head recorded with the final commit below. Desktop 1440×1000 and phone viewport 390×844, headless Chromium, reduced-motion preference. T3 preview snapshots timed out twice; Chrome connector was unavailable. The documented fallback used the repository's Playwright browser package with owned browser processes/contexts and actual UI inputs, uploads, buttons, reloads and saved-result verification.

- H01/H02: 20 calculated runs and 60 paychecks across three employees; per-run reconciliation, visible gross mismatch, preserved entries, correction, conversion, saved reload, no duplicate native history rows. Stale fingerprints, duplicate conversion/idempotent retry, identity and foreign-company guards exercised by backend specs.
- H03/H04: backend fixture verifies per-employee gross 40,000, net 32,940 and withholding 4,000; W-2 totals 120,000; all three Q1–Q3 filing types external/reference; Q4 October history 12,000 plus committed live November payroll 6,000 = 18,000; annual W-2/W-3 inputs 126,000. First live run calculates/approves using normal version-3 annual FICA evidence without fallback mode. No history check numbers, liabilities, Form 500 deposits, nonemployee checks, loan transactions, live YTD snapshots or enqueued jobs before genuine live commitment.
- H05: administrator success, ordinary accountant view and activation API 403; client grant/revocation covered separately in requests. Browser confirms view-only messaging and absence of reversal controls.
- H06: phone workflow adds a $100 manual October paycheck to the 20 source runs, with explicit FIT/SS/Medicare wages, earning component, register reconciliation and conversion/activation; 21 periods / 61 paychecks persisted.
- H07: browser reversal restores all 20 source runs and retains reversed archive evidence; backend rejects reversal after live commitment, with downstream uncommitted payroll or changed filing ownership.
- H08: desktop/phone workflow, no page-level horizontal overflow, real file upload, saved-state reload, keyboard focus/Enter to return to Client Management, and retired source bookmarks showing no payroll actions.

A read-only persisted-result check after the second browser activation found exactly 21 active periods / 61 active payments, gross and annual W-2 inputs 120,100, October history 12,100, 20 retired source runs, no check numbers or financial side effects, and next live check number unchanged at 701. The earlier browser checkpoint retained one reversed 60-payment archive; the repeated review-fix walkthrough now retains two such reversed archives (120 payments), both excluded from active totals. Source/register figures are synthetic; this does not certify Kasperbauer's actual dollars, documents or deposits.

Screenshots: [desktop reconciliation](prior-provider-history-20261101/reconcile-desktop.png), [phone saved review](prior-provider-history-20261101/review-phone.png), [phone activation](prior-provider-history-20261101/active-phone.png), [phone manual bases](prior-provider-history-20261101/manual-phone.png). Full logs, screenshots, fixture scripts and JSON receipts: `/Users/leonshimizu/Desktop/ShimizuTechnology/output/prior-provider-history-20261101/`.

Initial failures and retests: corrected the new Back to clients URL to `/settings/clients`; updated the single-provider registry expectation; retained QuickBooks-specific client wording for QuickBooks records; narrowed the cutover progress assertion to exact `2/2` text so dates cannot satisfy it. A concurrent frontend run timed out in unrelated employee/AIRE tests; a quieter full frontend gate rerun passed all 1,366 tests. Public browser suite rerun passed all 131. Original failure logs are retained outside Git.

Final automated gate evidence is recorded below. The first complete backend run encountered one old single-provider registry assumption, which was fixed. This draft is held regardless of gate results.

Limits: no real production/staging data, agency submission, deposit, provider transport, physical-device keyboard/gesture or human operator acceptance. Existing signed-document and actual-source verification remain production onboarding prerequisites. UI-created servers and browser processes were cleaned after browser QA; only isolated test DB work remains active until gate completion.

Final concurrency review found that filing-responsibility edits lacked the company lock used by activation/reversal. A separate-connection PostgreSQL probe reproduced a writer holding a responsibility row while waiting on the company's audit FK. The fix takes the company lock before any responsibility row is changed. The same probe then left the ownership row available to reversal while the writer waited on Company. A permanent nontransactional concurrency spec plus history/permission/filing request regressions passed: **21 examples, zero failures**. The complete backend suite on `07dbf908` passed: 5,722 examples, zero failures, zero pending, across all 528 spec files exactly once in four isolated roots/databases. The superseded initial full run had 5,720 examples and only the old single-provider expectation failed. Final frontend gate on the implementation head passed again with `VITEST_MAX_WORKERS=2` (1,366 tests); no timeout changes or test weakening were introduced.


## CodeRabbit review and fixes

CodeRabbit reviewed the full initial code (`22dd5a34`): 51 source/document files; four PNGs excluded by its path filter. It requested changes with 12 actionable items (11 inline threads plus the verified-tip reporting item in its review body). The review is not an approval of later changes.

The filing-ownership lock finding was already fixed in `07dbf908`, with a separate-connection regression. `b9164e39` addresses the other findings: retained paid-source provenance blocks approval/commit and live reports even after reversal; pre-tax adjustments prefill correctly; unified reports separate prior-provider counts and preserve explicit reported/paid-out tips; “select all” preserves reconciled edits; both auth sign-out paths clear sensitive drafts; candidate truncation is explicit; QuickBooks/source-neutral copy remains accurate. Focused backend regressions passed 70 examples; focused frontend regressions passed 11 tests.

The final frontend gate after these fixes passed **1,370 tests across 142 files**, TypeScript, ESLint and production-mode build. RuboCop passed all 1,597 files after two test-file blank lines were corrected; Brakeman reported zero errors/warnings; PostgreSQL integrity passed. Migration down/up on an unused task database passed (0.099 / 0.055 seconds). npm/Bundler audits found no vulnerabilities. Impeccable 4.6 advisory returned no findings.

Repeated 1440/390 browser acceptance passed conversion/reconciliation, preserved edits after returning to select-all, saved reload/activation, reversal with approval/commit/transmittal API rejection, phone manual entry, accountant read-only/403, canonical history de-duplication and retired links, keyboard return, and real account-menu sign-out clearing all user/client drafts. A harness run completed all product assertions but its cleanup record was lost during concurrent lifecycle bookkeeping; the lifecycle calls were serialized and the complete flow reran successfully with clean closure. The first new API start lacked this task's CORS origin; it was restarted locally with the exact origin before successful acceptance. These were local harness/setup failures, not waived acceptance cases.

CodeRabbit's next request was rate-limited (43 minutes until included allowance). One requested retry was posted after `b9164e39`; the lead must verify its resulting review state and current-head CI. No unavailable or stale review is described as clean. Final full-backend/public-browser results and cleanup are recorded below.


## Final gate and cleanup receipt

Tested code: **`b9164e39410c3fc997cee8c75936c6ad37472ef0`**. The following evidence commit changes only this ledger, refreshed screenshots, and two blank lines in test files; application behavior is identical.

- Full backend gate components: **5,725 examples, zero failures/pending/errors**, all 528 spec files exactly once across four separate Git roots and local PostgreSQL databases; RuboCop **1,597 files, no offenses**; Brakeman **zero errors/security warnings**. JSON receipt: `backend-gate-final-receipt.json`; per-shard JSON and logs retained in the requested output directory.
- Final frontend gate: **1,370 tests / 142 files**, TypeScript, lint and production build passed. Final public browser suite: **131 passed**. The earlier failure and superseded-run logs remain available; they are not counted as passing runs.
- Final saved-result verification after all browser suites: exactly **21 active periods / 61 payments**, **20 retired native source runs**, bridge/annual W-2 inputs **120,100**, October history **12,100**, next check number still **701**. No native/historical check numbers, liabilities, Form 500 deposits, nonemployee checks, loan transactions or live YTD snapshots. Two reversed 60-payment archives remain as excluded evidence following repeated reversal/reconversion acceptance.
- Browser resources, API 4137 and Vite 5177 were stopped after QA. The six exact task databases (`cp_prior_provider_20261101_dev`, `_test`, and `_gate_1`–`_gate_4`) and their synthetic local source files were removed. Four auxiliary gate worktrees/branches were removed. The requested held implementation worktree remains; no runtime handoff. Shared PostgreSQL/Redis/LM Studio/network services were not stopped. Lifecycle session: `01a19436-61e8-70c3-8682-4e897258fad6` (the actual resumed hook session, distinct from the parent brief's ID).

CI backend on `b9164e39` failed only RuboCop's two extra blank lines (`ci-backend-b916-job.log`); these are corrected and the complete local static gate passed. The evidence/formatting push triggers a fresh CI run. Current-head CI and a completed CodeRabbit re-review remain the lead's pre-merge gates. The draft stays HELD until after the production release. No merge or deploy was performed.


## staging-v2 release-candidate merge (2026-11-02)

`origin/staging-v2` at `e45f54dd` (#408 imported-paycheck FICA proofs, #409 DedicatedAdvisoryLock, #410 checklist, #411/#412 zero-liability reversal) was merged without rewriting history. The only textual conflict was the schema version line; both migrations remain and the schema version is `2026_11_01_090000`.

New regression `api/spec/services/prior_provider_history/pre_upgrade_source_runs_spec.rb` reproduces the read-only production shape recorded on 2026-11-02: three salaried per-period employees on a semimonthly profile, 20 calculated runs of 14 days (three 21-day: Apr 23–May 13, Jul 23–Aug 12, Oct 8–28), pay date equal to period end, gross $4,300 for the first two runs and $4,150 after. Items are calculated and then stripped of staging-v2-only calculation artifacts (`annual_fica_context`, earnings rounding and employer-match identity snapshots). The spec proves that upgraded approval of such a run demands recalculation, while selection, preview, conversion and activation use the saved rows unchanged (payroll item attributes identical before and after), create no checks, postings, deposits, tax-sync changes, jobs or email, and the first live run (Oct 29–Nov 11) calculates on the ordinary annual FICA path, approves and commits without a source review even though imported paychecks engage the conservative imported-history path. The release-day legacy inventory for the client stays clean. A second example covers an old calculation whose employer-contribution provenance is ambiguous: it now prefills blank for explicit entry instead of failing the selection page.

## Accountant access and ease-of-use pass (2026-11-02)

Access: any staff user who can run and commit the client's payroll (super admin, org admin, admin, manager, or accountant with access to the client) can view, save, record, turn on year-to-date and undo. Client and employee users, and staff without access to the client, get 403. The services recheck access under the business locks. Recording turns on Historical payroll for the client automatically.

Ease of use: five steps with a "What's left" list; every run, takeover date and paycheck is prefilled; employees are confirmed against roster SSN last four; paycheck and register problems show next to the field with the exact difference; progress autosaves to a shared per-client draft with stale-save protection; typed confirmation phrases are replaced by summary dialogs (pay dates, paychecks, totals, per-employee year-to-date) with a checkbox. The API still records the same acknowledgement constants.

Agent-executed local walkthrough (headless Chromium, `AUTH_ENABLED=false`, the only payroll user an assigned accountant, synthetic fixture with the recorded Kasperbauer run shape: 20 runs of 14/21 days, pay date on period end, $83,300 gross):

| Case | Result |
|---|---|
| Accountant opens the client from Client Management; can manage; 20 runs / 60 paychecks prefilled and selected; takeover Nov 1 | passed (1440) |
| Paycheck net and register gross differences shown inline with exact amount (−$10.00) | passed (1440) |
| Autosaved progress resumes at Match registers with 10 of 20 matched after reload | passed (1440) |
| Match registers at phone width, no page overflow; 21-day Oct 8–28 period listed | passed (390) |
| Record through summary dialog (checkbox required) → 20 pay dates / 60 paychecks | passed (1440) |
| Turn on year-to-date through dialog at phone width; Q1–Q3 provider / Q4 + W-2GU Cornerstone; survives reload | passed (390, 1440) |
| Saved API state: 20 periods, 60 paychecks, gross 83,300, 3 opening balances | passed |

Screenshots are in `docs/qa/prior-provider-history-20261101/`. Limits: resized headless browser, not physical devices or a human operator.
