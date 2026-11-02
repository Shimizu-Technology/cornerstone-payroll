# Prior-provider history: implementation and acceptance

Base: staging-v2 d7170343 (2026-11-01). Held; no deployment or production/staging data access.

## Product and evidence

Cornerstone staff calculate, approve and commit genuinely unpaid Guam payroll; client managers configure onboarding and filing ownership. See README.md, the Kasperbauer audit at output/payroll-aire-prod-audit-2026-10-30/kasperbauer/REPORT.md (S1–S34), and Brain-Dump/work/shimizu-tech/Cornerstone/payroll-priorities-and-aire-reconciliation-2026-09-19.md. Historical payments must enter dated historical snapshots and opening balances, never native commitment or settlement. The existing QuickBooks clean-client contract remains available.

This screen extends Client Management in place. Current access (superseding the original Nov 1 role model below): any staff user who can run and commit the client's payroll, including an accountant with access to the client, can record, activate and undo; client and employee users cannot. It inherits Cornerstone's neutral operational surfaces, primary actions, compact labels and responsive inputs. The five steps are select, reconcile, convert, review, activate. Inline validation preserves entries; saved state survives reload. No new animation: conversion and activation use busy controls and a settled status message. Phone verification is browser viewport coverage, not physical-device acceptance.

## Contract

One complete employer/year history, mapped to existing employees with source name and last-four identity checks. Retain provider evidence and operator-entered register totals per period; reconcile exact cents, including employer taxes and explicit FIT/SS/tip/uncapped Medicare bases. Calculations only prefill. Conversion retires sources atomically and retains their evidence. Activation locks snapshots, applies the normal opening bridge, and records quarterly/annual responsibility. No commitment service or outbound event is invoked. Reversal preserves audit/snapshots, removes inclusion and restores source runs before any live commitment; uncommitted downstream calculations must be discarded first to avoid stale context.

## Required acceptance ledger (agent executes, local synthetic fixtures)

| ID | Journey and expected saved outcome | Coverage | State |
|---|---|---|---|
| H01 | 3 salaried employees, 20 Jan 14–Oct 28 runs → reconciled 60 dated payments, source runs retired | backend + 1440 UI | passed (see execution below) |
| H02 | Register mismatch, stale preview, duplicate, overlapping/foreign employees rejected atomically | backend + recovery UI | passed (see execution below) |
| H03 | Activate: exact employee YTD, annual W-2/W-3 inputs, Q1–Q3 reference/external; Q4 October + live Nov | backend | passed (see execution below) |
| H04 | No historical instruments, obligations, deposits, loans, jobs/email; first live Nov calculates/approves normal FICA | backend | passed (see execution below) |
| H05 | Assigned accountant records, activates and undoes; client/employee roles and staff without client access get 403; client context and revoked access fail closed | backend + 1440/390 UI | passed (re-run Nov 2; see final section) |
| H06 | Manual period entry uses identical money/identity/reconciliation rules | backend + 390 UI | passed (see execution below) |
| H07 | Reversal before live commitment removes history once and restores source evidence; post-commit reversal rejected | backend + UI | passed (see execution below) |
| H08 | Desktop/phone select → reconcile → convert → review → activate, reload, keyboard/error states | 1440/390 browser | passed (see execution below) |

Full backend and frontend gates, migration up/down, db integrity, dependency audits, Impeccable advisory and public browser suite are recorded separately. Production registers, employee documents, deposit schedules, Q1–Q3 returns/receipts and October deposit reconciliation remain operator prerequisites. No actual filing, payment or external transport is in scope.

## Execution evidence

Agent-executed, synthetic local PostgreSQL, API 4137 and Vite 5177; head recorded with the final commit below. Desktop 1440×1000 and phone viewport 390×844, headless Chromium, reduced-motion preference. T3 preview snapshots timed out twice; Chrome connector was unavailable. The documented fallback used the repository's Playwright browser package with owned browser processes/contexts and actual UI inputs, uploads, buttons, reloads and saved-result verification.

- H01/H02: 20 calculated runs and 60 paychecks across three employees; per-run reconciliation, visible gross mismatch, preserved entries, correction, conversion, saved reload, no duplicate native history rows. Stale fingerprints, duplicate conversion/idempotent retry, identity and foreign-company guards exercised by backend specs.
- H03/H04: backend fixture verifies per-employee gross 40,000, net 32,940 and withholding 4,000; W-2 totals 120,000; all three Q1–Q3 filing types external/reference; Q4 October history 12,000 plus committed live November payroll 6,000 = 18,000; annual W-2/W-3 inputs 126,000. First live run calculates/approves using normal version-3 annual FICA evidence without fallback mode. No history check numbers, liabilities, Form 500 deposits, nonemployee checks, loan transactions, live YTD snapshots or enqueued jobs before genuine live commitment.
- H05 (superseded Nov 2): originally tested accountant read-only with activation 403. The final model lets an assigned accountant do every step; `prior_provider_histories_spec.rb` now covers accountant end-to-end success, 403 for client/employee/outside staff, and revoked/expired access inside the services. The accountant browser walkthrough is in the final section.
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

Repeated 1440/390 browser acceptance passed conversion/reconciliation, preserved edits after returning to select-all, saved reload/activation, reversal with approval/commit/transmittal API rejection, phone manual entry, accountant access (superseded by the Nov 2 accountant end-to-end success / client and outside-staff 403 checks), canonical history de-duplication and retired links, keyboard return, and real account-menu sign-out clearing all user/client drafts. A harness run completed all product assertions but its cleanup record was lost during concurrent lifecycle bookkeeping; the lifecycle calls were serialized and the complete flow reran successfully with clean closure. The first new API start lacked this task's CORS origin; it was restarted locally with the exact origin before successful acceptance. These were local harness/setup failures, not waived acceptance cases.

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

## Final release-current pass (2026-11-02, in progress)

Source brief: user brief for #407; this guide and QA ledger; Brain-Dump `work/shimizu-tech/Cornerstone/payroll-priorities-and-aire-reconciliation-2026-09-19.md` (distinct register columns, paid payroll must not be paid twice); private Kasperbauer audit `output/payroll-aire-prod-audit-2026-10-30/kasperbauer/REPORT.md`; release branch `08b5379e`. Production/staging versions in the user brief are background, not independently deployed-version verification here. `staging-v2` was merged without rewriting history as `b41541aa`. No textual conflicts. #407 remains draft/HELD; Claude alone owns merge after the release. No deployment is authorized.

Experience: accountants compare paid paper registers with saved calculations, enter old check numbers in a visible column, review/save evidence, and turn on YTD before genuinely unpaid payroll. Preserve exact-cents reconciliation, explicit bases, identity checks, source locks and document/approval gates. Use existing operational surfaces with no new motion. Resized desktop/phone browser coverage is not physical-device or CEO acceptance.

Agent-executed required final scenarios (synthetic local fixtures unless stated):

| ID | Starting conditions → actions → expected saved outcome | Coverage | Status |
|---|---|---|---|
| F01 | Past calculated runs, no live commitment → find notice in list/workspace; attempt approval → history link/guidance; live clients hide notice | API + desktop/phone | passed |
| F02 | Match registers → tab through old check numbers (leading zeros/blank allowed), save/reload → references retained without check allocation | desktop/phone + API | passed |
| F03 | Reconcile register mismatch, recover, record once → 20 periods / 60 paychecks with references in summary, saved view and imported detail | desktop/phone + API | passed |
| F04 | Turn on YTD/reload → next-number suggestion (highest numeric + 1), editable existing check settings, no automatic sequence write | desktop/phone + API | passed |
| F05 | Active history → create first live period → start after historical period end; payday after historical payday; operator confirms end/payday; saved new period | desktop/phone + API | passed |
| F06 | Six missing document requirements → visible pre-approval links to actual employee document manager; no waiver by activation | desktop/phone + API | passed |
| F07 | Fresh contained production copy → record/activate real company-10 shape using stand-in registers → 20/60 once; no historical checks/postings/deposits/loans/jobs/email; correct filing ownership/YTD | services/API | passed with limits below |
| F08 | Copy-only document waivers → Oct 29–Nov 11 live calculate/approve/commit → normal annual FICA; employee YTD = history + live | services/API | passed with limits below |
| F09 | Same 356 report requests for companies 1,2,4,5,6,10,11: staging before conversion vs final #407 after journey → other clients unchanged; company 10 expected history/live changes | contained copy | passed with limits below |

Private evidence is under `output/payroll-aire-prod-audit-2026-10-30/pr407-final/` (0600 files). Only synthetic screenshots and redacted counts belong in Git/PR. Real registers, actual document verification, filing/deposit evidence and the first unpaid payday remain operator decisions.

Final browser evidence (application code `590102fd`, synthetic isolated local database, accountant with explicit client-management grant): the complete Record → Turn on YTD journey ran at 1440 and 390 pixels; the saved-result checks also ran at 1280 and 390. All 60 old references retained leading zeros, autosave/reload resumed Match registers, monetary mismatch recovery worked, and 20 periods / 60 paychecks / 3 YTD balances were saved. Six document gaps remained after activation. The existing check settings suggested 7061, accepted an operator-edited 7065 and retained it after reload. The first live draft saved October 29–November 11 with a November 11 payday; the phone form was canceled before the desktop save to avoid duplication. No page errors or document-level horizontal overflow were found.

The initial browser run exposed a stale StrictMode load response that could overwrite recent input; commit `040877a9` fixes it and adds a delayed-response regression. A later harness assertion expected the wrong existing success message after saving the check number; the actual saved value was verified, and the resumed checks passed. Private original captures and scripts retain these failures and retests. Browser coverage used headless Chromium and resized viewports, not physical phones, Clerk sign-in, or CEO acceptance.

The screenshots below use synthetic data. The next-steps captures were refreshed on `4fd40b56` with a mocked one-gap example and a later historical payday. Earlier saved-check/settings captures use the complete synthetic fixture, with neutral identities/client label substituted in the screenshot DOM; no SSNs, real payroll identities, credentials or connection URLs are published.

| Desktop | Phone |
|---|---|
| ![Post-YTD next steps at 1280](prior-provider-history-final-20261102/next-steps-1280.png) | ![Post-YTD next steps at 390](prior-provider-history-final-20261102/next-steps-390.png) |
| ![Saved old check numbers at 1280](prior-provider-history-final-20261102/imported-checks-1280.png) | ![Saved old check number at 390](prior-provider-history-final-20261102/imported-checks-390.png) |

![Editable next check number in existing settings](prior-provider-history-final-20261102/check-settings-1280.png)

Independent financial review covered `69c6dc2d` plus the then-pending frontend fixes, followed by `dce8fc75`. It found reversal gating, non-taxable reconciliation and explicit deduction classification issues. Those were fixed in `dce8fc75`; the second round found that loan display consumers still needed a separate aggregate column. Commit `590102fd` adds that column to preview, CSV, PDF and spreadsheet only for verified prior-provider data, without assigning a native loan subtype. CodeRabbit completed reviews on `69c6dc2d` and `1ed01c5f` with changes requested. Material findings were then fixed in `4fd40b56`; final incremental coverage is reported separately.

### Completed contained production-copy rehearsal, Nov 2

The financial service/API journey ran on `590102fd`; seven conversion, activation, payroll lifecycle, FICA-context and controller source files remain byte-identical at report-comparison head `f4952ffb`. The final report services were exercised again at `f4952ffb`. This proves the named workflow using stand-in registers, not historical amount certification or full release acceptance.

- One onboarding and one batch recorded 20 periods / 60 paychecks / 3 workers, with two retained source files. Conversion/activation retries created no duplicate history or YTD bridge. Activation created three verified opening balances and 13 filing decisions: nine Q1–Q3 decisions owned externally, three Q4 decisions owned by Cornerstone, and one annual W-2GU decision owned by Cornerstone.
- Through activation, the native next-check setting remained 1, with zero native check allocation, liabilities/entries, deposits, loans, native YTD updates, jobs, emails or tax-sync effects. All 60 original source items and child data remained exact; the 20 source periods changed only their expected archival fields. Other-client/global business-row hashes remained exact.
- The real document gate blocked the first live run. After exactly six copy-only reviewed waivers, the October 29–November 11 run (paid November 11) calculated on the normal annual FICA path without fallback, approved and committed once: three items/checks, counter 1→4, one liability posting / 15 entries matching the live amounts. No jobs, emails, deposit submissions, loan transactions or tax-sync jobs occurred. Native YTD remained live-only; public YTD included history plus live once: 63 checks total, 21 per employee. All 30 employee/amount comparisons matched to cents. Repeated direct commitment was refused without saved changes or extra allocation.
- The final identical frozen manifest completed 356 requests: 351 expected HTTP 200s and five expected HTTP 404s. Other clients 1, 2, 4, 5, 6 and 11 have **zero differences across all 353 responses** from staging `08b5379e`. Twelve additional full canonical raw-body hashes and the masked-subtree hashes match exactly. No comparator ignore or tolerance was added. Company 10's three aggregate responses intentionally changed after conversion and live commitment; its final YTD employee rows, company totals and source summary equal the validated journey response.
- The first strict comparison found 49 metadata/wording additions despite unchanged monetary fields. It is retained as a failed diagnostic. Commit `f4952ffb` limits those additions to actual prior-provider history, preserving native/QuickBooks contracts. Four compatibility specs and an independent review with 16 additional in-memory assertions passed. The final full comparison supersedes that diagnostic. The final comparison is after the journey; no risky reset or final-head pre-conversion rerun was performed.

Limits: API previews and conversion/activation retries add audit rows; history/financial state is idempotent, but a literal zero-saved-change API claim is false. Report reads advance only the audit-log sequence while preserving saved rows/schema/storage. One public Float has a sub-cent representation difference; currency totals match to cents, not raw numeric identity. The fixture's non-taxable cash/retirement/Roth/insurance/loan classifications were zero, so their nonzero cases are covered by separate synthetic consumer regressions and independent checks. Original harness failures and corrected requests/assertions are retained privately. The worker's 136 passed checkpoints are checkpoints, not 136 independent acceptance scenarios.

Containment used process-level network denial, an exact owned loopback relay and fresh Neon endpoint/branch attestation before every native connection. No live Clerk/Resend/R2/AWS/AIRE credentials were supplied; only the three required record-encryption keys were extracted, and retained files used explicit local storage. Wrong-host, arbitrary-routing, subprocess TCP and reconnect-denial probes passed. Exactly one authorized production-child branch was created. That branch and endpoint were deleted and their absence verified; URL-bearing env/credential files, private runtime files and owned caches were removed. The copy worker has no remaining owned resources. Detailed receipts stay private, mode 0600.

Final engineering gate counts, exact tested SHAs, CI and current CodeRabbit coverage are recorded in the [PR body](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/407). They remain separate gates from this application-journey evidence. The PR stays draft/HELD; Claude owns merge. Real paid registers/check numbers, actual document verification or justified waivers, filing/deposit evidence, the client's next check stock number and the first unpaid payday still require the operator.


### Material review fixes and affected recovery checks, Nov 2

Application commit `4fd40b56` closes the final material CodeRabbit findings: autosave stops after a server failure and shows its reason until explicit retry or a new edit; the first-live start follows the historical period end, with payday constrained separately; a discarded draft cannot be resurrected by an old lock version; draft deletion shares the save lock and fresh authorization; Discovery and Plan use Guam's business date and the same candidate scope; activation labels combined totals; pending next-check input survives calibration/profile refresh; and filing-review access is refreshed and rechecked after waiting for the company lock.

The new real-browser mocked-API cases passed at 1280 and 390 pixels: failed autosave made only one PUT over six additional simulated seconds, explicit retry saved, reload restored the entered provider, and a historical payday after the period end still suggested the correct first-live start. The link retained the next-check suggestion and employee document repair context. No document overflow occurred. These four checks extend, rather than replace, the earlier real local-database 20/60 journey. The new screenshots were visually inspected.

A narrow independent review found no correctness regression in `674ffc3c..4fd40b56`. Its two test gaps were subsequently covered: an accountant assignment expires while the filing writer waits on Company, producing no filing/audit write; selecting a printer profile preserves an edited next-check number without saving the sequence. The existing calibration-save case also verifies the intended explicit sequence update. The initial expiry-test fixture lacked a required home company; that test-only setup failure is retained privately and the corrected real lock-wait case passed.

After two substantive CodeRabbit rounds, these valid nonblocking limitations remain: some supplementary deduction/source-sheet labels and legacy `quickbooks` count keys; attribution in mixed QuickBooks/provider component taxability (this onboarding rejects an existing mixed year); Form 941 source-mode metadata when provider wages occur only before the requested quarter; success messaging on replay of an already-reversed idempotency key (no financial replay); and QuickBooks list pagination when a page fills with provider batches. Evidence IO under the company lock, discovery batching and onboarding pagination remain performance follow-ups. No money, check allocation, filing ownership, tax-base or YTD defect was demonstrated by these residuals in the supported 20/60 workflow. They are not claimed fixed or covered by the production-copy fixture.

The production-copy branch was already deleted before these final safeguards/UI fixes. The financial journey remains pinned to `590102fd`, and the final 356-report comparison to `f4952ffb`; the new fixes have separate local regression/browser evidence. Final gate receipts and review status in the PR must preserve these source boundaries.
