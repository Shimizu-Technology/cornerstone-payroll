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

- H01/H02: 20 calculated runs and 60 employees/paychecks; per-run reconciliation, visible gross mismatch, preserved entries, correction, conversion, saved reload, no duplicate native history rows. Stale fingerprints, duplicate conversion/idempotent retry, identity and foreign-company guards exercised by backend specs.
- H03/H04: backend fixture verifies per-employee gross 40,000, net 32,940 and withholding 4,000; W-2 totals 120,000; all three Q1–Q3 filing types external/reference; Q4 October history 12,000 plus committed live November payroll 6,000 = 18,000; annual W-2/W-3 inputs 126,000. First live run calculates/approves using normal version-3 annual FICA evidence without fallback mode. No history check numbers, liabilities, Form 500 deposits, nonemployee checks, loan transactions, live YTD snapshots or enqueued jobs before genuine live commitment.
- H05: administrator success, ordinary accountant view and activation API 403; client grant/revocation covered separately in requests. Browser confirms view-only messaging and absence of reversal controls.
- H06: phone workflow adds a $100 manual October paycheck to the 20 source runs, with explicit FIT/SS/Medicare wages, earning component, register reconciliation and conversion/activation; 21 periods / 61 paychecks persisted.
- H07: browser reversal restores all 20 source runs and retains reversed archive evidence; backend rejects reversal after live commitment, with downstream uncommitted payroll or changed filing ownership.
- H08: desktop/phone workflow, no page-level horizontal overflow, real file upload, saved-state reload, keyboard focus/Enter to return to Client Management, and retired source bookmarks showing no payroll actions.

A read-only persisted-result check after the second browser activation found exactly 21 active periods / 61 active payments, gross and annual W-2 inputs 120,100, October history 12,100, 20 retired source runs, no check numbers or financial side effects, and next live check number unchanged at 701. The original 60-payment archive remains retained in reversed status and is excluded from active totals. Source/register figures are synthetic; this does not certify Kasperbauer's actual dollars, documents or deposits.

Screenshots: [desktop reconciliation](prior-provider-history-20261101/reconcile-desktop.png), [phone saved review](prior-provider-history-20261101/review-phone.png), [phone activation](prior-provider-history-20261101/active-phone.png), [phone manual bases](prior-provider-history-20261101/manual-phone.png). Full logs, screenshots, fixture scripts and JSON receipts: `/Users/leonshimizu/Desktop/ShimizuTechnology/output/prior-provider-history-20261101/`.

Initial failures and retests: corrected the new Back to clients URL to `/settings/clients`; updated the single-provider registry expectation; retained QuickBooks-specific client wording for QuickBooks records; narrowed the cutover progress assertion to exact `2/2` text so dates cannot satisfy it. A concurrent frontend run timed out in unrelated employee/AIRE tests; a quieter full frontend gate rerun passed all 1,366 tests. Public browser suite rerun passed all 131. Original failure logs are retained outside Git.

Automated gate and final commit details are appended after the final run. The first complete backend gate is still running at this checkpoint; one already-fixed old single-provider expectation was encountered. This draft is held regardless of gate results.

Limits: no real production/staging data, agency submission, deposit, provider transport, physical-device keyboard/gesture or human operator acceptance. Existing signed-document and actual-source verification remain production onboarding prerequisites. UI-created servers and browser processes were cleaned after browser QA; only isolated test DB work remains active until gate completion.

Final concurrency review found that filing-responsibility edits lacked the company lock used by activation/reversal. A separate-connection PostgreSQL probe reproduced a writer holding a responsibility row while waiting on the company's audit FK. The fix takes the company lock before any responsibility row is changed. The same probe then left the ownership row available to reversal while the writer waited on Company. A permanent nontransactional concurrency spec plus history/permission/filing request regressions passed: **21 examples, zero failures**. The complete backend suite is being rerun on this fix in four isolated roots/databases; the superseded initial full run had 5,720 examples and only the old single-provider expectation failed. Final frontend gate on the implementation head passed again with `VITEST_MAX_WORKERS=2` (1,366 tests); no timeout changes or test weakening were introduced.
