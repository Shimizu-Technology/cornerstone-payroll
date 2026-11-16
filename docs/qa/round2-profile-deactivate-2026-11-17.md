# Profile deactivation round 2

Product context: Cornerstone staff manage Guam payroll in Rails/React (README.md). Worker status events preserve employment history; draft/calculated rows are recalculable, approved runs require operator review before status changes. This follow-up addresses PR #469 review findings against origin/main 1d64bd46, including #467. No production access, merge, or deploy.

Acceptance and implementation:
- Explicitly selected workers with a deactivation event remain available for final, correction, and adjustment payroll.
- Employee detail includes open runs; the status dialog lists covering runs and blocks approved ones with an unapprove instruction. The service independently checks and locks those runs before either deactivation or termination.
- Recalculation destroys saved ineligible rows, even when omitted from the submitted roster, and reports name, status, and effective date. Terminated workers use the same handling. Explicit special-run selections remain authoritative.
- Dedicated inactive reasons, inactive icon, corrected date text, reactivation minimum after the latest status event, and explanatory text after both profile buttons.

Validation: 35 targeted RSpec examples passed (transition service/model, payroll calculation request, bounded detail read). RuboCop: 1849 files, no offenses. Brakeman: no warnings. ESLint and tsc -b passed. Impeccable advisory returned []. Full Vitest: 188 files / 1851 tests passed with maxWorkers=2. An earlier concurrent run timed out in unrelated document pagination; the complete reduced-worker rerun passed.

Agent-executed Chromium component QA used temporary synthetic fixtures and the real dialog, at 1280x800 and 390x844: approved run #42 displayed and submission disabled, all four inactive reasons visible, no horizontal overflow; cancel closed the dialog; switching fixture to draft enabled submission and explained recalculation. Backend specs verify saved outcomes. Full authenticated end-to-end payroll was not run. Safari/WebKit was not run on this headless Mac mini.

Temporary harnesses, Vite servers, and owned tabs were removed/stopped/closed. Test database cp_test_b7b is dropped at handback. Existing worktree and branch are retained for the lead; no runtime handoff.
