# PR B phone design-review follow-up

The lead requested aligned totals and usable tabs at 390×844. Source commit `0452f035` addresses both; `b02b0d12` repairs a release-test teardown race encountered during verification. A further refresh-lane change awaits the successful calculation response before polling saved status. Desktop labels and layout remain the same. First-screen employee name/net and compact results remain C.

The cell padding used for desktop dividers also applied to phone cells. Employees alone had its left padding removed, leaving Deductions and Net 12 px to the right. Phone cells now have no horizontal padding; desktop keeps its divider spacing. The same padding fix applies to read-only totals. Net stays last and spans both phone columns.

Phone navigation displays **Payroll · Checks · Reports · Activity**, with tighter spacing and hidden decorative icons. Full accessible names and the check count remain available. The row keeps native horizontal scrolling and its existing active-tab scroll positioning, bounded inside the page.

## Browser regression evidence

[Before geometry](phone-before-geometry.json) fails label/value alignment and fitting all four tabs. [After geometry](phone-after-geometry.json) passes all eight checks, including direct Reports/Activity/Checks loads and no page overflow.

| Phone position | Before B review | After fix |
| --- | --- | --- |
| Employees label and figure x | 16 | 16 |
| Deductions / Net label and figure x | 28 | 16 |
| Gross / DRT label and figure x | 207 | 195 |
| Net cell width | 358 | 358 |
| Activity tab right edge | 555.73 | 319.58 |

The earlier totals probe measured cell boxes, which missed the text indentation. The new release-lane assertions measure both label and value edges, compare each column, require Net after DRT at full width, and require all four phone tab links inside the viewport. No assertions were removed.

Both contact sheets were recaptured for all seven states at 1280×800 and 390×844; raw captures include all four tabs. Axe now covers **30 captures**, including all seven phone states and phone dashboard: zero required #377 rule-family violations. Impeccable 4.6.0 returns `[]`. The normalized inventory still has **567 rows / zero unexplained removals**. See GATES.json and the refreshed read-only, motion and source receipts for the final verification run.

The first release rerun failed because a dashboard race-test route handler was still fetching when its browser context closed. The failure surfaced in the following serial test. That test now awaits `page.unrouteAll({ behavior: 'wait' })` before closing. This waits for the handlers rather than ignoring their errors. The red log is retained in task output at `pr-b/review-phone/release-teardown-red.log`.

No API code changed. The existing 5,090-example backend gate is reused against the identical API tree `a66bfef045d5cae61cf27aec0c1660f73a5a6341`. The web gate and all four browser lanes were rerun for the phone revision; exact counts are in GATES.json. Current cleanup receipts accompany the evidence. The worktree remains held for the lead’s review and merge.

Refresh also exposed a five-second status poll timing out before calculation finished; the asserted private database showed the run saved as calculated afterward. The case now awaits the actual calculation, approval and commit POST responses, asserts success and zero calculation errors, then checks saved status. All payroll amount/loan assertions remain. The red log and saved-status receipt are retained in task output.

The subsequent run exposed the same short commit poll; the saved private DB showed committed afterward. All three transitions in that case now wait for their successful HTTP responses and use the existing lane’s 30-second persisted-state bound. This is scoped to the standalone-deduction flow; no global timeout or application behavior changed.

The F1/F2 follow-up additionally tests real read-only report permissions at both widths, restores parallel help, and refreshes all four browser lanes. The full web gate now covers 126 files / 1,189 tests. See FINDINGS-RESPONSE.md for the current review response and actual saved-outcome evidence.
