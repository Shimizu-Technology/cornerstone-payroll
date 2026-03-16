# Post-Review Findings - 2026-02-24

## Purpose

This document tracks suspected issues found during a broad review after the recent payroll, reporting, correction, check-printing, and W-2/941 changes. Each item starts as a hypothesis and must be verified with code inspection, build/test execution, or targeted reproduction before it is treated as a confirmed defect.

Status values:

- `pending`: identified in review, not yet fully verified
- `confirmed`: verified with code/test/build/runtime evidence
- `resolved`: fixed and re-verified
- `disproved`: reviewed and not a real issue
- `needs_product_decision`: behavior is risky/ambiguous and needs policy clarification

## Findings Checklist

### Frontend Build And Type Safety

1. `resolved` - `web/src/services/api.ts`: `W2GuFilingReadinessResponse` is referenced but not imported into the type import list.
2. `resolved` - `web/src/components/payroll/CorrectionPanel.tsx`: unused `deletedRunId` fails TypeScript build under current settings.

### Pay Period Detail / Import / Recalculation

3. `resolved` - `web/src/pages/PayPeriodDetail.tsx`: `canImportMosa` depends on `payPeriod.company_id`, but the pay period detail payload does not serialize `company_id`, which can hide the import action.
4. `resolved` - `web/src/pages/PayPeriodDetail.tsx`: after import completes, `hoursMap` stays stale, so recalculation can overwrite imported hours.
5. `resolved` - `web/src/pages/PayPeriodDetail.tsx`: employee hour entry UI only loads the first 100 active employees, while backend recalculation still processes all active employees.

### Payroll Corrections / Checks / Reporting / Tax Sync

6. `resolved` - `api/app/services/pay_period_correction_service.rb`: correction void/copy logic filters on `payroll_items.voided`, which is used elsewhere to mean "voided check" rather than "exclude this employee from payroll correction math".
7. `resolved` - `api/app/controllers/api/v1/admin/reports_controller.rb`, `api/app/services/form_941_gu_aggregator.rb`, `api/app/services/w2_gu_aggregator.rb`: voided source pay periods and committed correction runs are both counted in reports/exports because queries only filter on committed status.
8. `resolved` - `api/app/controllers/api/v1/admin/pay_periods_controller.rb`, `api/app/services/payroll_tax_sync_payload_builder.rb`, `api/app/services/pay_period_correction_service.rb`: tax sync treats correction chains as ordinary committed payroll because correction metadata is not communicated downstream.
9. `resolved` - `api/db/migrate/20260310000002_add_void_reprint_to_payroll_items.rb`, `api/app/models/company.rb`: check number uniqueness is enforced globally even though numbers are allocated from company-local sequences.

### Filing / Export Math And Compliance

10. `resolved` - `api/app/services/form_941_gu_aggregator.rb`: 941-GU line 2 double counts tips by adding `reported_tips` to `gross_pay` even though payroll calculators already include tips in gross.
11. `resolved` - `api/app/services/w2_gu_aggregator.rb`: W-2GU Box 1 and Box 5 double count tips for the same reason.
12. `resolved` - `api/app/services/form_941_gu_aggregator.rb`: line 1 uses quarter-wide distinct employee count instead of the 12th-of-month filing rule.
13. `resolved` - `api/app/services/form_941_gu_aggregator.rb`: additional Medicare threshold resets each quarter instead of using year-to-date wages.
14. `resolved` - `api/app/services/w2_gu_aggregator.rb`, `api/app/services/form_941_gu_aggregator.rb`: Social Security wage base configuration for 2026 is incomplete or incorrect.
15. `resolved` - `api/app/services/w2_gu_preflight_validator.rb`: SSN readiness checks can accept malformed partial SSNs because they rely on `ssn_last_four`.

### Reporting UX

16. `resolved` - `web/src/pages/Reports.tsx`: `markFilingReady` discards backend `revalidation` findings and shows only a generic error, hiding fresh blockers from operators.

### Verification Environment

17. `resolved` - backend RSpec verification is currently blocked in this environment because `bundle exec rspec` fails to load `levenshtein-ffi` native artifacts.
18. `resolved` - frontend lint is currently failing in `AuthContext.tsx`, `CorrectionPanel.tsx`, and `api.ts`, so the current branch is not lint-clean.

## Detailed Verified Notes

### 1. Frontend build is red

- Verified by running `npm run build` in `web/`.
- Current failures:
  - `web/src/services/api.ts`: missing `W2GuFilingReadinessResponse` import
  - `web/src/components/payroll/CorrectionPanel.tsx`: unused `deletedRunId`

### 2. MoSa import and recalc flow has real state bugs

- `PayPeriodDetail` gates import UI on `payPeriod.company_id`.
- `pay_period_json` does not serialize `company_id`, so that condition can evaluate false even for the correct company.
- `handleImportComplete` updates `payPeriod` and `payrollItems` but never rebuilds `hoursMap`, so the next recalculation can send stale hours.
- The page only loads the first 100 active employees, but `run_payroll` defaults to recalculating every active employee in the company.

### 3. Correction workflow is not isolated from check-void workflow

- `PayrollItem#void!` is explicitly about check voiding.
- `PayPeriodCorrectionService` skips `voided` payroll items during YTD reversal and when copying items into correction runs.
- Result: voiding a paper check can accidentally change correction/YTD behavior.

### 4. Reporting and tax sync do not understand correction chains

- Reports/dashboard/export queries still select by `status = committed` without excluding `correction_status = voided` or selecting only net-effective runs.
- Tax sync payloads include no correction metadata, and correction voiding does not emit a compensating sync event.
- Result: original and replacement payroll runs can both be counted as real payroll.

### 5. Filing math issues are confirmed

- Payroll calculators include tips inside `gross_pay`.
- 941/W-2 aggregation code adds `reported_tips` again on top of `gross_pay`.
- 941 line 1 uses quarter-wide distinct employee count.
- Additional Medicare logic resets at quarter start instead of using YTD wages.
- 2026 Social Security wage base is wrong/incomplete:
  - verified externally: 2026 SSA base is `$184,500`
  - W-2 code hardcodes `176,100`
  - 941 code has no 2026 base configured

### 6. W-2 preflight can greenlight malformed SSN data

- `Employee#ssn_last_four` strips non-digits and returns the last four digits of whatever remains.
- `W2GuPreflightValidator` only checks whether `ssn_last_four` is present.
- Result: partial or malformed SSN values can pass readiness checks.

### 7. W-2 mark-ready UX drops useful backend validation detail

- Backend returns `revalidation` payloads when mark-ready fails or succeeds.
- Frontend currently clears preflight state and only shows a generic error message instead of surfacing the new findings.

### 8. Verification environment itself has issues

- `bundle exec rspec ...` currently fails before examples run because `levenshtein-ffi` cannot load its native extension.
- `npm run lint` currently fails with:
  - unused variable in `CorrectionPanel.tsx`
  - `AuthContext.tsx` lint errors around `setState` in effects, `any`, and fast-refresh export shape
  - unnecessary escapes in `api.ts`

## Verification Log

### 2026-02-24

- Created initial findings log from code review.
- Confirmed frontend build failure with `npm run build`.
- Confirmed `web/src/services/api.ts` is missing `W2GuFilingReadinessResponse` from its type import list.
- Confirmed `web/src/components/payroll/CorrectionPanel.tsx` contains an unused `deletedRunId` that fails TypeScript build.
- Confirmed `PayPeriodDetail` import/recalc issues by inspecting `canImportMosa`, `handleImportComplete`, and the employee list fetch cap.
- Confirmed correction/check semantics conflict: `payroll_items.voided` is used for check voiding but also used to exclude items from correction reversal/copy logic.
- Confirmed reports/exports and tax sync only key off committed status and currently ignore correction chain state.
- Confirmed 941/W-2 tip double-counting by comparing the aggregators against payroll calculator `gross_pay` behavior and existing report specs.
- Confirmed 941 line 1 and Additional Medicare quarter-reset problems from aggregator implementation.
- Verified externally that the 2026 Social Security wage base is `$184,500`; current code uses `176,100` in W-2 logic and has no 2026 config in 941 logic.
- Confirmed W-2 preflight uses `Employee#ssn_last_four`, which only strips digits and takes the last four, allowing malformed partial SSNs to appear valid.
- Confirmed `Reports.tsx` drops backend `revalidation` findings on mark-ready failure.
- Attempted targeted backend RSpec verification, but the suite cannot boot because `levenshtein-ffi` native artifacts are missing in the local Ruby environment.
- Ran `npm run lint` and confirmed the frontend is not lint-clean in its current state.
- Fixed frontend build/lint blockers in `api.ts`, `AuthContext.tsx`, and `CorrectionPanel.tsx`; `npm run build` and `npm run lint` now pass in `web/`.
- Fixed `PayPeriodDetail` import gating, full active-employee loading, explicit `employee_ids` recalc payloads, and `hoursMap` resync after import/recalc.
- Fixed correction semantics so check void state no longer changes correction/YTD behavior.
- Added correction-aware report filtering and correction metadata in tax sync payloads; voiding now refreshes tax-sync state and enqueues a sync job.
- Scoped check-number uniqueness by company via `payroll_items.company_id` and a company-level partial unique index.
- Corrected 941/W-2 math for gross/tips handling, SS wage-base handling, line 1 counting, and Additional Medicare YTD threshold behavior.
- Tightened W-2 readiness SSN validation to require a full 9-digit SSN and surfaced backend revalidation findings in `Reports.tsx`.
- Rebuilt the local `levenshtein-ffi` native extension, migrated the Rails test database, and re-ran targeted backend specs successfully.
- Verified the fixed areas with `bundle exec rspec spec/models/company_check_spec.rb spec/services/pay_period_correction_service_spec.rb spec/requests/api/v1/admin/reports_spec.rb spec/models/employee_ytd_total_spec.rb spec/services/payroll_tax_sync_payload_builder_spec.rb` -> `137 examples, 0 failures`.
