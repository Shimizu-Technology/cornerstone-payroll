# MoSa files: PR 1 QA ledger

## Scope and baseline

Implementation and agent-executed acceptance for the November 14, 2026 client-portal plan, PR 1. Verified clean task worktree and HEAD = origin/main = `4308f5f6b1689afecb016c79c526ff12a1c69c6a` before editing. Branch: `t3/mosa-payroll-file-intake`. Lead owns independent review, merge and deployment; this PR is held.

Sources: Leon's task; `output/portal-mosa-plan-20261114.md` (PR 1, decisions 1–2 and findings 4–5); `output/mosa-walkthrough-feedback-20261114.md`; current submission/import code. These private planning files live outside the repository in ShimizuTechnology. Cornerstone staff review client source files before applying real payroll. MoSa uses Revel hours plus an Excel workbook for tips/loans. A missing workbook must never be silently mistaken for complete source coverage. Fixed-pay clients do not use this intake.

Acceptance: persist one workbook choice independent of structured changes; retain all revision evidence; verify staff workbook bytes identically to portal source; explicitly audit any pay-run import used for a pending revision, limited to the same company and regular pay period. Preserve the existing payroll parser and calculation rules.

## Required journeys

All cases are agent-executed on an isolated local stack. Required viewports are desktop 1440 and mobile browser 390 (responsive browser coverage, not native device coverage).

| Case | Fixture, action and expected saved outcome | Desktop | Phone | Status |
| --- | --- | --- | --- | --- |
| U1 | MoSa sends PDF + workbook; confirmation identifies both; staff reviews and applies both retained sources | passed | passed | passed |
| U2 | MoSa sends PDF + https link; staff downloads and attaches workbook; review/apply retains uploader/time/file/hash against immutable revision | passed | passed | passed |
| U3 | MoSa explicitly chooses no tips/loans; staff sees that choice and may apply without a blocking warning | passed | passed | passed |
| U4 | Excel in Other files prompts to move; yes populates workbook slot; an unresolved misplaced workbook is refused by API | passed | passed | passed |
| U5 | Pay-run Import MoSa with pending revision; explicit audited selection applies and clears Calculate gate; foreign/stale selections refused | passed | passed | passed |
| U6 | Non-MoSa client has no Home card/nav/form; direct API submission refused | passed | passed | passed |
| R1 | Fresh production branch: practice copy through Oct 5–18, Oct 19–Nov 1 paid Nov 5, real source upload, manual email items, calculate and compare period 117 | passed | n/a | passed |
| R2 | Same isolated rehearsal with portal link + staff workbook; same financial outcome | passed | n/a | passed |
| R3 | Company 6 fingerprints identical before/after; delete only task Neon branch | passed | n/a | passed |

Private payroll files and screenshots remain under `output/`; no customer PII or credentials belong in this ledger or GitHub.

## Engineering checks

Implementation source commits: `2f705699ed347f814fef81a429ab196955b35e24`, file-picker fix `281d2271`, and integration `7e665b74`, followed by the regular-purpose refusal and matching fixture update in this ledger’s commit. Final source changes were tested before committing; no documentation-only status is implied. Local engineering runs use an isolated task database; browser fixtures use a separate isolated database and local filesystem storage, with outbound Ruby TCP blocked and real notifications disabled.

- Backend submission/import/parser batch: 244 examples passed. Command: `bundle exec rspec spec/requests/api/v1/payroll_submission_periods_spec.rb spec/requests/api/v1/admin/portal_payroll_imports_spec.rb spec/requests/api/v1/admin/payroll_imports_spec.rb spec/services/payroll_submissions spec/services/payroll_import spec/models/payroll_submission_tenancy_spec.rb spec/requests/company_switcher_spec.rb`.
- Final submission/evidence batch after staff history metadata: 104 examples passed. Final focused runs also passed: 59 portal import examples (including a pay-run upload with no portal revision) and 32 client request examples (including authentication before company gating).
- Existing intake and retained-source regressions: 54 examples passed (`spec/services/payroll_intake`, intake requests, intake document destroy and source package model specs).
- `bundle exec rubocop`: 1,832 files, no offenses. `bundle exec brakeman -q`: 0 errors, 0 warnings.
- `npm run lint` and `npx tsc -b`: passed.
- Full Vitest before the final file-picker cleanup: 175 files, 1,749 tests passed (`npm test -- --maxWorkers=2`).
- Impeccable advisory scan of changed form/import components: no findings.
- Heavy full backend suite: not run locally. `asus-test` failed before test execution with SSH “banner exchange: Connection to UNKNOWN port 65535: invalid format”. Full backend coverage remains for CI. No credentials or customer data were transferred to ASUS.

U1–U6 passed with actual browser interaction on a synthetic stack at 1440×900 and 390×900. All four workbook paths verified both the success receipt and persisted import association; link review retained staff workbook metadata; the pay-run case verified a 422 refusal before selection, explicit selection/apply, and successful calculation afterward. The non-MoSa client had no entry/nav and a direct route returned Home. API and model suites separately verify field refusals, tenancy, stale revision selection, rollback, size/signature/checksum verification, immutable records and legacy serialization.

Initial automation failures were fixture/locator/timing issues: five-second receipt timeout, incomplete owner name, incorrect menu text, hidden phone navigation, and checking Calculate while its Hours section was collapsed. Runs were corrected and fresh synthetic fixtures used for client resubmission. Screenshots and logs, including original failures, are private under `output/pr1-mosa-files-20261114/`; no private images are attached to this PR.

## Production-copy rehearsal

Verified Neon project `royal-haze-68941541`, parent `br-bitter-unit-a1dagbos`, task branch `pr1-mosa-files-20261114` / `br-mute-fire-a1izcitq`, endpoint `ep-mute-union-a1eu7mhc`. The live API verification runs before every new database client. Rails uses test mode, E2E identities, local retained storage, outbound network blocking and no email/Clerk/AIRE credentials.

Two independent practice copies were created through Client Management, with committed history copied through Oct 5–18 and a new Oct 19–Nov 1 run paid Nov 5. Upload route completed: 52 employees, with all compared hours, tips, loans, taxes, gross and net amounts matching the paid run except the expected single employee +$0.01 gross/net difference. The missing 68 manual hours were entered through the worksheet; the $219.70 requested loan was then collected automatically, with no hand-edited loan workaround. The separate link practice copy produced the same 52-row result, again with only the expected +$0.01 gross/net difference. Both comparisons also cover retirement, insurance, loan payments, total additions/deductions and employer taxes/contributions. Staff evidence verification confirmed one immutable client PDF plus link, two verified retained importer sources, staff identity/time, and a retained workbook checksum equal to the original downloaded bytes. Link-route rehearsal uses the real local downloaded workbook with a placeholder HTTPS link; external OneDrive availability is not tested.

The first link-copy attempt rolled back on a repeatable-read serialization conflict with simultaneous activity updates of the actor. Retrying through the UI with a dedicated local rehearsal staff identity succeeded. This is a fixture/runtime limitation outside PR 1. Remote-database import exceeded the initial browser response timeout; persisted status confirmed successful apply before resuming the manual hours step.

The existing global WebSocket-ticket cleanup removed one expired company-6 ticket in the copy. All company-6 payroll/business fingerprints are unchanged. An auxiliary child at the exact branch-birth LSN verified the original ticket against the baseline hash and retained it for exact fixture restoration after stopping the API; that auxiliary branch was deleted. After stopping the rehearsal API, only that exact already-expired ticket was restored and verified against its original hash. The complete company-6 fingerprint is identical: zero added, removed or changed records. Both the rehearsal branch and the auxiliary birth-snapshot branch were deleted, confirmed through the Neon API. No parent/production database connection or write was used.

## Integration and review

PR #456 is held for the lead. CodeRabbit initially reported its free OSS review limit; no completed review is claimed. Quality was dispatched explicitly at `281d2271` because the PR was conflicting with newly merged main and no automatic pull-request run appeared. That superseded run was cancelled after integration; automatic final-source Quality checks are running on subsequent pushes. Main advanced from the verified starting `4308f5f6` to `739eb9bd` (the portal shell/practice-copy work). Integration at `7e665b74` preserves the current Pay Period Files naming and practice-copy visibility together with this PR's capability gate. All six browser journeys passed again at both 1440 and 390 widths on fresh fixtures and the integrated API/frontend. The inherited MoSa practice fixtures in browser/request coverage were explicitly marked with `mosa_revel` to honor the new contract.

Post-integration frontend lint and TypeScript passed. The 15 affected layout, import and submission files passed all 81 Vitest tests with one worker and a 30-second timeout budget. A broad post-integration attempt hit five-second timeouts in two unchanged AIRE/document tests under machine load and was stopped; both failing cases then passed in isolation with the same assertions and the 30-second budget. No unrelated production code or assertions were weakened. The earlier full suite passed 1,749 tests; a completed full post-integration local frontend run is not claimed. Full-suite CI remains the final broad check.

The first integrated backend batch had 253 passes and one inherited practice-fixture failure: it expected Payroll Files on a company with no intake source. Configuring that positive MoSa fixture fixed it; all eight practice-portal request cases passed. The final combined targeted batch then passed 254 examples with zero failures. The final portal-import request file then passed 60 examples with zero failures, including refusal when the linked run changes to a bonus purpose. Final RuboCop remained clean across 1,832 files and Brakeman reported zero warnings/errors.

## Resource ownership

Lifecycle session `01a1d939-2d06-7e70-899e-5d8785d67fd3`. Baseline audited before starting resources. Existing Postgres/Redis, Chrome/device resources and other listeners are borrowed and protected. All task API servers, proxies, Vite, shared-preview tab and bounded Chromium runners were stopped/closed. `dev-lifecycle cleanup` and `status` report no active owned resources. No runtime handoffs. Both Neon branches were deleted. Shared Postgres/Redis, user tabs, simulators and other sessions were left unchanged. The held branch/worktree, isolated synthetic test databases and private QA evidence are retained for the lead; no server remains connected. Disposable worktree dependencies and generated caches were removed after verification.

## Lead handoff

Hold PR #456 for independent review and CI. Do not merge or deploy from this implementation task. One backward-compatible migration adds a nullable legacy-safe workbook choice and staff evidence/source-route fields. Apply the API migration and expose the company capability before relying on the new web gate during a later deployment.

The financial rehearsal uses the same import/calculation code as the integrated branch; main's intervening changes affect the portal shell/history visibility. Fresh browser fixtures exercised the combined API/frontend after that integration. All required U1–U6 and R1–R3 scenarios have passed. Remaining broad checks are the final-head CI suite and the lead's independent review; CodeRabbit requested changes on `7e665b74`; the late findings and follow-up verification are recorded below. Final-head re-review remains pending.

Private evidence: `output/pr1-mosa-files-20261114/`, including browser run logs/screenshots, `reconciliation-13.json`, `reconciliation-14.json`, `link-evidence.json`, `company6-fingerprint-result.json`, and `neon-cleanup.json`. Do not upload these private artifacts to GitHub.

## Late reviewer findings and verification

CodeRabbit completed its review of `7e665b74` during handoff and requested three changes. All were checked against the code and addressed: Apply/Back and the apply handler now refuse action during a staff workbook preview; submission retry identity includes SHA-256 bytes so a corrected same-name, same-size workbook gets a new key while identical retries keep theirs; pay-run revision eligibility/building lives in `PayrollSubmissions::PayRunSelection`, with explicit deferred persistence and company/period validation. The existing successful apply transaction still owns persistence.

The two delayed-preview resolve/reject cases and interrupted same-size replacement case pass in Vitest. The service extraction passes all 60 portal-import request examples, including selection refusals and rollback. Frontend lint and TypeScript pass; the final full RuboCop scan passes 1,833 files and Brakeman reports zero warnings/errors. Final affected frontend run: 15 files, 84 tests passed. All six browser journeys passed again on fresh synthetic fixtures at both 1440 and 390. The 390 link review additionally delayed the upload request and verified both Apply and Back disabled until the refreshed review arrived. Evidence is in private `browser-review-1440.log`, `browser-review-390.log`, `vitest-review-affected.log`, and `rspec-review-service.log`. The first complete CodeRabbit review is changes-requested, not approval; the follow-up push is rate-limited until review allowance resets. Lead independent review and final-head checks remain required.
