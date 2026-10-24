# Pay-run redesign — PR B

Owner: `payroll-redesign`. Base `origin/staging-v2` `34c99bb2`, including PR A #383 and late-hours #382. Held for the lead to recheck and merge.

One header shows period, client, pay date, purpose, run number, status, linked attention, a filled next action and secondary-action overflow. Saved totals use a neutral divided strip. Payroll, Checks & payments, Reports and Activity retain existing guarded tools and dialogs. The processing controller stays mounted to preserve worksheet edits and filters across tabs. Read-only modes retain their summary; writer `overview` URLs redirect without changing return context. Client portal code is unchanged.

Checks, non-employee/FIT/Form 500, holds and manual reconciliation moved to Checks & payments. Reports, final record, sign-off and liabilities moved to Reports. Notes, lifecycle/activity, timecards and corrections moved to Activity; corrections are linked from header overflow. Drafts retaining records keep their former Overview review action under Saved payroll records.

## Acceptance evidence

- [Desktop contact sheet](contact-1280.jpg) and [phone contact sheet](contact-390.jpg): seven states, before and after. All 56 final tab/viewport captures are retained in task output.
- [Measurements](MEASUREMENTS.md): run 2 at 1280×800 falls from 7,115 px / 8.89 screens to 2,255 px / 2.82 screens; totals y 275 → 164; results table y 1,358 → 1,116. Header, status, attention, filled action and totals fit together. **First-screen employee name/net acceptance remains pending C**, as agreed with the lead. Collapsed steps and compact results remain C.
- [Every action’s new location](ACTIONS.md), [machine diff](actions-location-diff.json): **567 normalized rows; zero unexplained removals**. There are 64 before pages and 18 final state/viewport records, including parallel help and late-hours entries. Thirteen guarded action components retain byte-identical hashes; ReportsDownloadPanel has the explicit F1 read-only change. Writer report locations remain unchanged.
- [Review responses](FINDINGS-RESPONSE.md): phone totals align, Net is last/full-width, all four short tabs fit. Read-only Reports exposes six permitted GET artifact types and excludes editors/save-capable generators. Parallel-comparison help is restored beside status.
- [Gate/QA ledger](GATES.json): API **5,090 examples, zero failures/pending**; RuboCop **1,481 files, zero offenses**; schema/integrity/security pass. The API tree is unchanged, so its full gate receipt is reused. Web npm ci/audit and final TypeScript/lint/test/build gate pass: **126 files / 1,189 tests**. Browser **public 131, release 45, refresh 10, pay-items 24**, with no failures/skips in final runs. Red logs and the reasons for test-readiness repairs remain in task output; financial assertions were retained.
- Seven review regressions failed before and pass after. The focused 31-test run includes the original report-dialog handoff tests. Twelve real-permission browser cases cover direct `/reports` and Payroll → Reports in all three read-only modes, at both widths: **27 successful preview GETs, three verified PDF downloads, zero POST attempts/403s**. Payroll/document records are [unchanged](review-saved-state-receipt.json); audit/activity writes are excluded from that snapshot.
- Earlier eight affected-flow and six read-only UI records remain in the ledger, separately from the twelve new real-permission cases. Six final normal/reduced-motion dialog/totals recordings verify focus containment/return, scroll preservation and saved calculation/reload ($3,000 then $3,025). [Motion receipt](final-motion-results.json). [Phone geometry](phone-after-geometry.json) passes eight checks; Net spans both columns.
- [Axe summary](axe-summary.json): **30 scans, zero required #377-family violations**. Legacy-results advisories remain recorded for C. [Impeccable 4.6.0](impeccable.json): no findings.

## Integration, review and limits

No API, schema, dependency, deployment or migration changes. Late-hours source/cockpit entry components are unchanged from #382; existing guards, admin entry and saved return link were verified. Financial late-hours execution, physical devices/printers, real providers/payments/filing/email and the separate two-app certification lane were not run. Its navigation selectors remain maintained. Copied connected screens retain their inherited readiness guards; no successful provider import is claimed.

The lead’s independent review at `d0a3291b` found F1 (P2) and F2 (P3), now addressed with regression and real-browser evidence. The final fix head awaits the lead’s recheck. CodeRabbit’s one requested review was rate-limited; no completed bot approval is claimed. Earlier bounded review is preserved in [code-review.md](code-review.md).

[Verified source](verified-source.json) and [cleanup](lifecycle-final.txt): no active owned resources. Exact owned wrappers/browsers stopped; five recreated private databases dropped and the prior backend-test database remains removed. All assigned ports 48741–48749 are free. Borrowed/protected services were preserved. Worktree/branch are retained for review and C after the lead merges B.
