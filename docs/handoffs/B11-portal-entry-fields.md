# B11 — configured portal entries

November 17, 2026. Base: origin/main 80ed984beb6551d209bbc91738100702c350244f (B4 merged). Worktree: /Users/agent/work/worktrees/cp-p2-portal-entries; branch feat/portal-entry-fields. Lead owns independent review, integration, merge and deployment. No production access.

## Behavior and decisions

The existing PayrollStandingChange is the configuration and standing_change_id is the evidence identity. Portal users see one section of labeled amount/hour fields with help, required/optional indicators, and None this period only where allowed. Employee/job identity comes from configuration. Generic changes remain separate; No changes affects those only. Optional blank fields are omitted. Required available fields must have an answer on client and server. Unavailable fields are hidden from client entry forms, including carried revision answers, and remain flagged in staff detail/Expected entries/Settings.

Configured labels are snapshotted in immutable revision change rows. Revision cards display configured answers even alongside No changes. New revisions preserve previous answers while taking current configuration metadata.

ImportChanges retains field ID, revision and previous applied value in proposals/payroll evidence. The existing review prefill applies mapped employee salary or saved-job hours. Staff adjustments require a reason; the existing import raw_data and audit metadata retain it. Entering fresh staff pay after a skipped prior owner answer remains the existing explicit pay decision. No second calculator was introduced.

None answers create audited PayrollEntryResolution rows inside the existing apply transaction, with source_evidence containing submission_id and revision. Applying a newer revision replaces only this submission period’s client-owned resolutions; staff resolutions are preserved. Stale or unavailable mappings block apply rather than guessing an employee/job. Expected entries show From client: revision N for imported values and none answers. Owner worksheet overrides stop showing client provenance when their period-pay source is cleared, using the existing behavior.

Migration 20261117000200 adds resolution source_evidence and relaxes the No changes database constraint to allow configured answers. Deploy requires the normal migration before application code.

## Integration overlap

ImportModal.tsx has a small change in the client-change review section: reason input/validation/submission for edited values and previous → current value text. Coordinate that hunk with #472/#473; intake-preview behavior was not intentionally changed. ClientPayPeriodDetail, PayrollReviewPackage and notifications were not edited. ExpectedEntriesPanel and PeriodParts have small display changes.

## Verification

- 224 relevant RSpec examples passed across payroll submissions, expected entries, tenancy, portal import requests, variable salary import and lifecycle. A subsequent 56-example focused run passed with added configured-hours mapping/audit and client-versus-staff availability coverage (overlapping the earlier run).
- Full Vitest unit suite: 190 files, 1,859 tests passed before final backend-only validation changes; final rerun recorded in PR. Command: npx vitest run --exclude '**/e2e/**' --maxWorkers=2. An unfiltered Vitest invocation also collects Playwright specs and fails collection; the exclusion runs the complete unit suite, with no unit tests excluded.
- Frontend lint and tsc -b passed. RuboCop changed Ruby files passed; Brakeman zero warnings. Impeccable advisory returned [].
- Database migration up/down/up succeeded on the dedicated local test database before QA; schema load and request validation also verified the updated constraint. Down was exercised before creating new-answer evidence.

Agent-executed Chromium QA, synthetic company and portal contact, API 5427/web 5428:
1. 1280×800: configured labels/help, no employee/job pickers; prohibited None absent. Attached synthetic PDF, selected no tips/loans and No changes. Sending blank required entries was blocked. Entered owner pay 1200, another owner None, and 38 hours; revision 1 saved.
2. 390×844: opened update; amounts/none/hours carried forward. Changed owner pay to 1300 and hours to 40, retained source PDF, saved revision 2. Revision 1 remained superseded. Revision 2 visibly listed configured answers despite No changes. No horizontal overflow.
3. Applied the submitted rows through ImportChanges and PayrollImport::ImportService using a local synthetic source-disposition fixture and verified test tax table. Owner salary_override=1300; hourly mapped job regular_hours=40 at rate 20; other owner resolution source revision=2; expected outstanding empty.
4. Staff pay-run UI at 390×844 and 1280×800 showed owner Filled $1300, hourly Filled 40h and owner None, all three tagged From client: revision 2. Document width matched viewport at both sizes.

Limits: staff Apply/PDF parsing, adjustment reason entry and old→new display were covered by automated tests, not a complete browser import journey. No approval/commit. No physical phone, WebKit or mobile Safari coverage. Browser evidence preceded the final mapping guards and test-only additions. Lead should exercise full staff intake review after integrating overlapping ImportModal work.

## Cleanup and next action

Task API/frontend processes and owned preview tab closed. Lifecycle manual-20261117-010537-51765-f124 reports no owned resources. cp_test_p2_entries is dropped after final checks; shared PostgreSQL is borrowed and remains available. Preserve this clean worktree for lead review. Lead must assess final PR checks and independent review, reconcile ImportModal overlap, and run the complete staff import browser journey before calling that acceptance complete.

## Round 2 — November 17, 2026

The assigned worktree was clean at 2152eb2a. Fetched and merged origin/main first: already up to date at 80ed984b (#468 included); schema version unchanged. No shared checkout edits, production access, merge or deploy.

All six independent-review findings were addressed. Current configuration clears carried `skipped` when None is prohibited. Normalization checks availability before accepting None. Apply now ignores stale None mappings and records `stale_none` decisions with a reason in the successful import record, rather than aborting the transaction. Saved/workbook pay choices require a reason even when the numeric client draft is untouched. ImportModal uses separate adjustment and decline reason state; its changes remain localized to the client-change controls and payload. Indexed server errors appear once in the summary, and configured required inputs expose aria-required. Revision availability warnings are staff-only, with configured fields and employee/job associations loaded in batches.

Agent-executed Chromium acceptance, synthetic Entry QA company 952/pay run 391, local test DB only:

- At 1280×800, the client submitted revision 1: Owner 1 $1200, Owner 2 None, Maintenance Worker 38 hours; retained PDF contained 2 baseline hours. Staff opened Review these submitted files, documented Owner 2's payroll exclusion separately from the configured None answer, confirmed the client values and used Apply. API returned 200, two successes, one reasoned exclusion. Expected entries showed Owner 1 $1200, Owner 2 None, Maintenance Worker 40 total hours, all From client: revision 1. Verified at 1280 and 390×844.
- At 390×844, client Update carried the prior answers and retained PDF; client changed Owner 1 to $1300 and sent revision 2. Staff review showed Previous entry: 1200.00 → This revision: 1300.00 at both widths. Staff changed the review amount to $1250, entered “Client confirmed corrected period amount”, chose client pay, recorded Owner 2's exclusion and used Apply on mobile. API returned success. Expected entries showed Owner 1 $1250, Owner 2 None, Maintenance Worker 40 total hours, all From client: revision 2, at both widths. Document width equalled viewport width throughout the checked panels/review.
- DB verification: import 276 applied; Owner 1 salary_override 1250; decisions retain submitted amount 1300.00, previous value 1200.00, reviewed/applied value 1250 and the correction reason. Maintenance Worker retained 2 baseline + 38 client hours without double counting. Owner 2's old client resolution was replaced by source revision 2. Local verification outputs: /tmp/cp-r2-db-rev1.log and /tmp/cp-r2-db-rev2.log.
- The adjustment was exercised while applying revision 2, after verifying revision 1's filled panel; an already-applied revision cannot be reapplied. The first attempted revision-1 Apply correctly rolled back because the synthetic Maintenance Worker profile rate 15 did not match its saved job rate 20. Corrected the fixture to primary job/profile rate 20, refreshed preview and reran successfully. No payroll writes were made through service shortcuts.

Limits: Chromium viewport simulation only; physical phone, WebKit/mobile Safari, approval/commit and deployment were not run. The local test auth proxy selected synthetic users through the existing test-only E2E header; no real identity/provider sends. Ownership session manual-20261117-013112-57754-0974: API 58726, Vite 58501, test proxy 58505 and preview tab closed; lifecycle reports no owned resources. Shared PostgreSQL remains borrowed. Preserve this worktree/branch for the lead's review and integration with #472/#473.

Final round-2 gates: fresh-database targeted RSpec 198 examples/0 failures; full Vitest 190 files/1,862 tests; lint and tsc -b passed; full RuboCop 1,854 files/no offenses; Brakeman zero warnings; Impeccable []. The first post-browser RSpec run used leftover synthetic QA rows and failed count assertions; recreating the dedicated database restored the clean-fixture contract and all 198 passed. cp_test_p2_entries was dropped after final verification. Round-2 code has not yet received independent final-head review; the lead owns that gate and cross-PR integration. This section supersedes the earlier stale-None blocking behavior and missing browser acceptance notes.

## Round 3 — November 17, 2026

Pulled the assigned branch, then merged origin/main 0209afe9 (#470) without conflicts. The merge and implementation commits have model Co-Authored-By trailers. The shared checkout was not edited. No production access, merge or deployment.

Narrow fixes:
- Stale None uses the same current-mapping validation for review warnings and apply. The configured snapshot label appears with instructions to enter a value or ask the client. The successful import note, apply response (`manual_review_warnings` and `client_change_decisions`) and saved decisions retain it. Valid None still creates a resolution; stale None still skips it.
- Revision Update carries configured answers only through the available fields in the client payload. Omitted fields cannot return as generic changes. Vitest verifies an earlier answered field is absent and the update sends without it.
- Adjustment reasons clear alongside all other review state at the four requested reset points. ImportModal changes stay limited to those resets for integration with #472/#473.

Verification: 200 targeted RSpec examples passed (`import_changes`, `catalog_and_rows` containing ChangeRows, admin payroll imports, portal payroll imports, client payroll submission periods). After a final note-format cleanup, the full 117-example portal import request suite passed again. Full Vitest: 191 files / 1,870 tests passed, excluding Playwright e2e specs as in earlier rounds. Lint, `tsc -b`, full RuboCop (1,857 files), Brakeman (zero warnings) and advisory Impeccable (`[]`) passed. The initial RSpec invocation used nonexistent filenames; the corrected suites above passed.

Agent-executed Chromium affected-flow check: the real ImportModal rendered the synthetic preview captured from the new passing stale-None request test. At 1280×844 and 390×844, scrolled the review to read the complete warning, confirmed the configured label and recovery instructions, and verified document width equalled viewport width. Evidence: /tmp/cp-r3-stale-none-1280.png, /tmp/cp-r3-stale-none-390.png, /tmp/cp-r3-browser.log. Backend request coverage verifies preview warning, successful Apply response, persisted import note/decision and absence of a stale resolution. Browser did not execute Apply this round; retained PDF downloads were mocked in the focused rendering check. No physical phone, WebKit or Safari coverage. T3 preview could not open localhost (connection refused); local Playwright Chromium performed the check.

Runtime cleanup: lifecycle manual-20261117-014437-60311-e37d reports no active owned resources. Owned Vite and browser closed, temporary browser harness removed; shared PostgreSQL stays available. Dedicated cp_test_p2_entries dropped after verification. Preserve this worktree and branch for lead review; the lead owns round-3 independent review and cross-PR integration. CodeRabbit's prior success context accompanied a rate-limit comment, with no submitted PR reviews, so it is not evidence of final-head review.
