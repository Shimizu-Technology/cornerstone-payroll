# Profile deactivation round 3 — lead handoff

Worktree: `/Users/agent/work/worktrees/cp-b7b-deactivate`, branch `feat/profile-deactivate`, PR https://github.com/Shimizu-Technology/cornerstone-payroll/pull/469. Latest main merged at `80ed984b` (#468, including #467), merge commit `a312f216`. Hold for lead review: do not merge or deploy. No production access.

Cornerstone payroll staff need to preserve saved paychecks while resolving workers who no longer belong on regular runs. Sources: README, Employee.eligible_for_period, EmployeeStatusTransitionService, PayPeriodLifecycleService, PayrollExpectedEntries, and the existing PayrollItemEditModal removal action. The required outcome is explicit removal or reactivation before approval/commit, preserving termination's existing date boundaries and special-run selections.

Implemented:
- Removed automatic payroll-item destruction from recalculation. Existing ineligible rows are skipped and retained, including explicit selections and list-triggered special-run recalculation. No dependent AIRE or FICA evidence deletion is attempted.
- Added a read-only regular-run eligibility projection using Employee.eligible_for_period for inactive/termination status. Reasons include the worker, status, and known date. Approval and commit independently reject unresolved workers. The panel appears alongside Expected entries; its instructions point to Edit payroll → Remove from Payroll. Final/correction/adjustment runs are exempt.
- Status changes and dialog listing share EmployeeStatusTransitionService.open_runs. It selects draft/calculated/approved regular runs with a payroll item for the worker and end_date >= effective_date, including runs starting later. The dialog fetches this server result for the selected date, disables submission while checking or on failure, links to company-scoped runs, blocks approved runs with an unapprove instruction, and explains explicit removal for calculated/draft runs.

Acceptance evidence (agent executed, local synthetic fixtures):
- Nov 15 status date / Nov 16–30 run: approved blocks both deactivation and termination; calculated is listed, status transition succeeds, approval and commit reject the stale row; removal clears this gate. Service tests cover both actions.
- Final-pay row for a terminated worker survives list-style recalculation without a worker selection, with unchanged attributes.
- An AIRE-allocated ineligible payroll item and its allocation survive recalculation.
- Eligibility boundary tests retain a worker whose status date is inside the run, preserve termination eligibility on the start day, exclude inactivity on the start day, and clear the warning on reactivation.
- Employee GET listing excludes earlier, committed, and special runs, using the selected date.

Validation:
- Full targeted RSpec set includes status transitions/events, employee eligibility, new run eligibility, run-payroll and pay-period requests, lifecycle concurrency, pay_period_detail_read_spec (including query budget), expected entries/resolutions, and employee requests. Final result: 264 examples, zero failures.
- Full Vitest: 190 files / 1,861 tests passed with maxWorkers=2. Dialog tests rerun after final text/link changes: 5 passed.
- ESLint, tsc -b, full RuboCop, and Brakeman passed; Brakeman reports zero warnings. Impeccable advisory: [].
- Early RSpec runs used db:prepare seeds that introduced annual tax configs incompatible with legacy synthetic snapshots; an interrupted concurrency fixture also left a user behind. Recreated only cp_test_b7b from schema without seeds; clean runs pass. The final-pay test setup was corrected to change run purpose while draft. New date-boundary specs freeze Nov 17 explicitly to avoid Rails UTC/local date differences.

Chromium QA: real dialog in a temporary component harness, synthetic server/status responses; 1280x800 and 390x844. Both deactivate and terminate: approved plus calculated runs listed, links present, approved submission disabled, no horizontal overflow. Calculated-only: explicit removal instruction visible, submission enabled, submission callback succeeds and dialog closes. Full authenticated end-to-end payroll and real mobile/Safari interaction were not run. Final company-scoped link destinations are asserted in Vitest; earlier Chromium navigation checked the compatible legacy run links.

Owned temporary harness files, Vite server, and browser tab removed/stopped/closed. Lifecycle session `manual-20261117-010545-51900-9490` reports no active owned resources. cp_test_b7b is dropped before handback; shared PostgreSQL remains running. Worktree and branch retained for the lead. Next: independent review of this round's head and CI inspection; no review-clean or merge-readiness claim is made by this implementation worker.
