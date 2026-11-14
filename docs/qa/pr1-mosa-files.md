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
| R1 | Fresh production branch: practice copy through Oct 5–18, Oct 19–Nov 1 paid Nov 5, real source upload, manual email items, calculate and compare period 117 | not_run | n/a | not_run |
| R2 | Same isolated rehearsal with portal link + staff workbook; same financial outcome | not_run | n/a | not_run |
| R3 | Company 6 fingerprints identical before/after; delete only task Neon branch | not_run | n/a | not_run |

Private payroll files and screenshots remain under `output/`; no customer PII or credentials belong in this ledger or GitHub.

## Engineering checks

Implementation source commit: `2f705699ed347f814fef81a429ab196955b35e24`. The final ledger commit changes documentation only. Local engineering runs use an isolated task database; browser fixtures use a separate isolated database and local filesystem storage, with outbound Ruby TCP blocked and real notifications disabled.

- Backend submission/import/parser batch: 244 examples passed. Command: `bundle exec rspec spec/requests/api/v1/payroll_submission_periods_spec.rb spec/requests/api/v1/admin/portal_payroll_imports_spec.rb spec/requests/api/v1/admin/payroll_imports_spec.rb spec/services/payroll_submissions spec/services/payroll_import spec/models/payroll_submission_tenancy_spec.rb spec/requests/company_switcher_spec.rb`.
- Final submission/evidence batch after staff history metadata: 104 examples passed. Final focused runs also passed: 59 portal import examples (including a pay-run upload with no portal revision) and 32 client request examples (including authentication before company gating).
- Existing intake and retained-source regressions: 54 examples passed (`spec/services/payroll_intake`, intake requests, intake document destroy and source package model specs).
- `bundle exec rubocop`: 1,832 files, no offenses. `bundle exec brakeman -q`: 0 errors, 0 warnings.
- `npm run lint` and `npx tsc -b`: passed.
- Full final Vitest: 175 files, 1,749 tests passed (`npm test -- --maxWorkers=2`).
- Impeccable advisory scan of changed form/import components: no findings.
- Heavy full backend suite: not run locally. `asus-test` failed before test execution with SSH “banner exchange: Connection to UNKNOWN port 65535: invalid format”. Full backend coverage remains for CI. No credentials or customer data were transferred to ASUS.

U1–U6 passed with actual browser interaction on a synthetic stack at 1440×900 and 390×900. All four workbook paths verified both the success receipt and persisted import association; link review retained staff workbook metadata; the pay-run case verified a 422 refusal before selection, explicit selection/apply, and successful calculation afterward. The non-MoSa client had no entry/nav and a direct route returned Home. API and model suites separately verify field refusals, tenancy, stale revision selection, rollback, size/signature/checksum verification, immutable records and legacy serialization.

Initial automation failures were fixture/locator/timing issues: five-second receipt timeout, incomplete owner name, incorrect menu text, hidden phone navigation, and checking Calculate while its Hours section was collapsed. Runs were corrected and fresh synthetic fixtures used for client resubmission. Screenshots and logs, including original failures, are private under `output/pr1-mosa-files-20261114/`; no private images are attached to this PR.

## Production-copy rehearsal (in progress)

Verified Neon project `royal-haze-68941541`, parent `br-bitter-unit-a1dagbos`, task branch `pr1-mosa-files-20261114` / `br-mute-fire-a1izcitq`, endpoint `ep-mute-union-a1eu7mhc`. The live API verification runs before every new database client. Rails uses test mode, E2E identities, local retained storage, outbound network blocking and no email/Clerk/AIRE credentials.

Two independent practice copies were created through Client Management, with committed history copied through Oct 5–18 and a new Oct 19–Nov 1 run paid Nov 5. Upload import applied; manual email inputs and final calculation/reconciliation are in progress. Link-route rehearsal uses the real local downloaded workbook with a placeholder HTTPS link; external OneDrive availability is not tested.

The first link-copy attempt rolled back on a repeatable-read serialization conflict with simultaneous activity updates of the actor. Retrying through the UI with a dedicated local rehearsal staff identity succeeded. This is a fixture/runtime limitation outside PR 1. Remote-database import exceeded the initial browser response timeout; persisted status confirmed successful apply before resuming the manual hours step.

The existing global WebSocket-ticket cleanup removed one expired company-6 ticket in the copy. All company-6 payroll/business fingerprints are unchanged. An auxiliary child at the exact branch-birth LSN verified the original ticket against the baseline hash and retained it for exact fixture restoration after stopping the API; that auxiliary branch was deleted. Final full fingerprint and task-branch deletion remain to be recorded.

## Resource ownership

Lifecycle session `01a1d939-2d06-7e70-899e-5d8785d67fd3`. Baseline audited before starting resources. Existing Postgres/Redis, Chrome/device resources and other listeners are borrowed and protected. Task servers and bounded Chromium runners were claimed by exact identity. Synthetic API/proxy processes and the shared-preview tab have been stopped/closed and released. The isolated rehearsal API, Vite/proxy and active rehearsal browsers remain task-owned until the final cleanup recorded below.
