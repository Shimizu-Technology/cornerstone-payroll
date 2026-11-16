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
