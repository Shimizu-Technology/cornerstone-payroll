# Pay-run redesign — PR B

Owner: `payroll-redesign`. Base `origin/staging-v2` `34c99bb2`, including PR A #383 and late-hours #382. Held for the lead to review and merge.

One header shows period, client, pay date, purpose, run number, status, linked attention, a filled next action and secondary-action overflow. Saved totals use a neutral divided strip. Payroll, Checks & payments, Reports and Activity retain existing guarded tools and dialogs. The processing controller stays mounted to preserve worksheet edits and filters across tabs. Read-only modes retain their summary; writer `overview` URLs redirect without changing return context. Client portal code is unchanged.

Checks, non-employee/FIT/Form 500, holds and manual reconciliation moved to Checks & payments. Reports, final record, sign-off and liabilities moved to Reports. Notes, lifecycle/activity, timecards and corrections moved to Activity; corrections are linked from header overflow. Drafts retaining records keep their former Overview review action under Saved payroll records.

## Acceptance evidence

- [Desktop contact sheet](contact-1280.jpg) and [phone contact sheet](contact-390.jpg): seven states, before and after. All four tabs were captured at both widths in the task output.
- [Measurements](MEASUREMENTS.md): run 2 at 1280×800 falls from 7,115 px / 8.89 screens to 2,255 px / 2.82 screens; totals y 275 → 164; results table y 1,358 → 1,116. Header, status, attention, filled action and totals fit together. **First-screen name/net acceptance is pending C**, per the lead. Steps and compact results remain for C.
- [Action inventory with every new location](ACTIONS.md), [machine diff](actions-location-diff.json): 525 normalized state/viewport/action rows; zero unexplained removals. Raw before/after, source inventories and hashes of 14 unchanged guarded action components are included.
- [Gate and QA ledger](GATES.json): API 5,090 examples; RuboCop 1,481 files; schema/integrity/security pass. Web npm ci/audit/gate passes: 125 files / 1,182 tests. Browser public 131, release 45, refresh 10, pay-items 24; zero skips or failures in the final runs. The final full web gate uses two Vitest workers to avoid shared-Mac timing contention; earlier timeout logs remain in the output directory.
- Four new regressions cover writer alias/navigation, correction refresh reaching retained Checks panels, staged values surviving delivery-method saves, and paper-check counts excluding deposit stubs. Existing connected-draft coverage now asserts a filled primary. Browser selectors changed with the moved controls; assertions were retained. An employee-route race selector now identifies the intended company request.
- Fourteen UI execution records cover focus containment/return, scroll/filter context, both widths and motion preferences, edits across tabs through calculation/reload ($3,000 then $3,025 gross), all three read-only modes, and late-hours guards/admin entry/return navigation. Six named dialog/totals recordings are in the output directory; the final rerun is recorded in [final-motion-results.json](final-motion-results.json). [Phone totals positions](phone-totals-final.json) confirm Net spans both columns below Deductions and Payable to DRT.
- [Axe summary](axe-summary.json): 13 desktop/phone captures; zero required contrast/select/landmark/heading/ARIA violations. Existing legacy-table empty-header/name advisories remain for C. [Impeccable 4.6.0](impeccable.json): no findings.

## Integration and limits

No API, schema, dependency, deployment or migration changes in B. The late-hours source/cockpit entry components are unchanged from #382. Financial late-hours execution was not repeated; B verifies its existing guards, admin dialog entry and saved original-run link. Physical devices, real providers/printers and the separate two-application connected certification lane were not executed. That lane's navigation selectors were maintained for the new tabs.

[Bounded code review](code-review.md) found and closed a correction refresh seam and duplicate draft method controls. Later retention fixes pass regression and release tests. Lead review and CodeRabbit status are reported on the PR, without claiming approval here.

[Cleanup](lifecycle-final.txt): no active owned resources. Exact owned servers/browsers stopped; six asserted private databases dropped. Borrowed/protected services unchanged. Worktree and branch retained for review and C after the lead merges B.
