# Feedback navigation and salary-hours review fixes

Five CodeRabbit comments are addressed in application commit b374803a.

- r4367423892: the page records the previous feedback fields for the payroll route. Only a newly published nonempty field or error attempt triggers a redirect. Retained notices, tab changes and clearing another message do not count as new outcomes. Pending focus survives the redirect and waits for confirmation-dialog focus restoration. Three regressions cover each other tab after calculation; two cover new commit/rollback failures from Reports, including repeating the identical message after returning to Reports.
- r4367423884: the shared compact hours readout follows the detailed salary predicate. Without a timekeeping source or positive recorded hours, enabled/default base salary shows “Not recorded”; disabled base salary shows “—”. A known source with zero hours remains 0.00. Six cases assert both desktop and phone DOM. Footer registerTotals remains unchanged.
- r4367423881: hours and rowMenu explicitly return ReactNode.
- r4367423887: renderSource explicitly returns PayRunSectionProps<'source'>.
- r4367423877: new test callbacks declare void or Promise<void>; assertions remain.

The initial focused reproduction had six failures and five passes (other tests intentionally filtered out). The complete three-file targeted run passes 139 tests, including repeated identical errors. A command accidentally launched from the repository root did not find the web test configuration; it is retained as targeted-repeat.log and its temporary cache was removed. The correct web-directory run passed.

The refresh browser lane now checks Reports, Checks and Activity immediately after successful calculations on desktop and phone, then returns to Payroll and continues its existing approval/commit and financial assertions.

The first all-green unit retry exposed a required-boolean typing error in the legacy salary fixture during the production build. Commit 973f61f2 omits the legacy field instead of assigning undefined; its runtime assertion is unchanged. The complete web gate is rerun after that test-fixture correction.

The final full web gate passed TypeScript, zero-warning lint, **131 files / 1,259 tests**, and production build on application/test commit `973f61f2` (UI logic b374803a). Release passed **45** and refresh **10**, with zero failures, skips or flaky results. The added tab checks run as part of the existing refresh journeys and keep their saved wages, deductions, loan balance and commitment assertions.

The first full gate passed 1,258 tests and failed one unchanged ChecksPanel download-cleanup timer assertion while the host load average exceeded 50. ChecksPanel then passed all 30 tests in isolation, and the complete gate passed on retry. No production or test-timeout change was made for that failure. The original failed receipt/log remains in review-3; the green gate and browser receipts are in review-3/final-gate.

Twelve headless presentation checks passed across 1280×800 and 390×844: flat fee, recorded salary, salary without a record (enabled/default handling is also covered by unit tests), excluded base salary, known zero-hour salary record, and hourly split. No page or main-content horizontal overflow. Presentation-only GET overrides leave saved payroll amounts unchanged. [Desktop stress capture](worst-flags-1280.png) · [Phone stress capture](worst-flags-390.png) · [12 receipts](hours-qa.json). The two stress captures are refreshed; broad contact sheets and measurements remain the accepted previous-round evidence.

No API, migration or dependency changes. Backend specs were not rerun under the web-only C scope. Public/pay-items lanes and broad axe/motion/read-only acceptance remain prior-round evidence; this round reruns exactly the requested web, release and refresh gates.

Raw logs, failed reproductions, green receipts and cleanup: `output/payroll-aire-review-2026-10-24/impl/payroll-redesign/pr-c/review-3/`.

All owned servers, Chromium processes and four private databases were cleaned. The nine assigned ports are free; lifecycle session 01a16ca4-4d6a-7673-a7d7-bc69d9795376 reports no active owned resources. Borrowed/protected services were unchanged. Worktree and branch remain for the lead to merge.
