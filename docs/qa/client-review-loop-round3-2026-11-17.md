# Client review loop — round 3

Implementation worker: GPT-6.1 Sol. Branch `feat/client-review-loop`, continuing merged base `8556494ef56355ba7a8fab6e117b55f28dedd565` for PR #475. The lead owns final-head review, CI, merge and deployment. This worker did not access production, merge or deploy.

Cornerstone staff calculate and approve payroll before publishing a client preview. When client review is enabled, the client decides on that exact revision before commit. Commit is the financial boundary. Requested or sent-but-unaccepted client files require a staff acknowledgement at commit; they do not prevent payroll indefinitely. Sources: the lead's round-3 brief, `PayrollReview::RevisionService`, `PayPeriodLifecycleService`, `PayrollHistoryQuery`, `PayrollSubmissions::Serializer` and the shared commit dialog.

## Decisions and implementation

Disabling client review treats published reviews as unpublished for client access. Both client list/detail projections, preview downloads and the locked decision service check the current company setting. Finished payroll remains readable with no review card/history while disabled. Review evidence is preserved; disabling the setting does not mutate or supersede packages or silently discard a pending change request. Re-enabling makes the retained current review available again if the run is still approved. This avoids withdrawal and republication side effects for a reversible setting. Company-before-period decision locking serializes decisions with setting changes; refused decisions produce no staff notification.

A pending change request suppresses Commit on the list with either setting. Older files periods linked to open runs say “Payroll in progress” when client review is disabled. The staff review panel describes disabled reviews as retained history and offers no email attestation; finalized pending reviews keep their finalized/history copy.

The detail and list commit dialogs show outstanding requests, including sent files awaiting acceptance. Confirmation requires a checkbox. The lifecycle service rechecks requests under lock and refuses commit without `acknowledge_outstanding_file_requests`. Successful commit audit metadata records that acknowledgement and each outstanding request's ID, title and status. Requests remain open after commit. Existing check-number guidance and change-request blocking remain in the shared dialog.

Only `stale_payroll_review_revision` triggers the client card's reload/message/acknowledgement reset. Other validation errors retain their server message and do not reload. Regression coverage distinguishes stale approval, change request and PDF errors from ordinary 422/409 failures.

The four supplied CodeRabbit threads were checked against the merged branch. The review-ID attestation reset and its controller test, finalized pending-review copy, live-run source-correction guard and staff-first setting description were already present. This round adds coverage for finalized/disabled review copy and correction of a legacy-paid period before commit, followed by refusal after commit. Inline replies document the final verification.

## Agent-executed browser acceptance

Synthetic fixtures only in `cp_test_p2_loop`; Rails test mode, real local API, temporary identity proxy, disabled email transport. The setting was changed through the isolated fixture runner after publication. This checks client visibility after a real setting update; it does not certify editing company settings through the settings screen. Browser dimensions were 1280×800 and 390×844, with pointer input. Physical-phone keyboard, PWA, printer, bank settlement and real email delivery were outside scope.

| Case | Expected and verified outcome | 1280px | 390px |
| --- | --- | --- | --- |
| R3-01 | Confirmed published preview. After disabling, approved run absent from client history and direct access refused; finished payroll readable without the card. No decision notifications. | passed | passed |
| R3-02 | Pay-run dialog lists outstanding file request, Confirm disabled until acknowledgement; acknowledged commit persists with open request and commit audit. | passed | passed |
| R3-03 | List opens the same request-bearing dialog, requires acknowledgement, and saves acknowledged commit/audit. | passed | passed |

Three cases accepted, none failed/blocked/not run. All four acknowledged runs saved gross $1,200.00 and net $1,100.00. No horizontal page overflow was observed. These are browser viewport checks, not native-device certification. [Saved records and audit metadata](client-review-loop-round3-2026-11-17/saved-outcomes.json) independently confirm outcomes. Visual evidence: disabled-client direct access at [desktop](client-review-loop-round3-2026-11-17/desktop-disabled-review.png) and [phone](client-review-loop-round3-2026-11-17/phone-disabled-review.png), acknowledgement in the detail dialog at [desktop](client-review-loop-round3-2026-11-17/desktop-detail-acknowledgement.png) and [phone](client-review-loop-round3-2026-11-17/phone-detail-acknowledgement.png), and the [desktop list dialog](client-review-loop-round3-2026-11-17/desktop-list-acknowledgement.png). The phone list screenshot preceded panel paint and is excluded; its checkbox interaction, disabled-state check and saved audit were verified separately.

## Automated verification

Final clean-database RSpec: **201 examples, zero failures**. Full Vitest: **194 files, 1,910 tests passed**; the strengthened open-dialog attestation regression also passed separately. Frontend lint and `tsc -b` passed. Full RuboCop: **1,889 files, no offenses**. Brakeman: **zero warnings**. Public client-approval E2E: **2 passed**. Advisory Impeccable scan: **no findings**. The backend batch covers the review loop/revision service, lifecycle and concurrency, staff/client pay periods, history query, submissions serializer/source corrections, portal file requests and detail-read equivalence/query budgets. These checks cover the final implementation tree; the final unit follow-up changes only the attestation test setup to explicitly open its dialog.

The initial regression run exposed new-fixture mistakes (missing factory/annual context), extra detail-read work and lint formatting; these were corrected. A supplementary backend run overlapped the browser-seeded database and failed on fixture slug/global-notification assumptions. The final backend run uses a freshly recreated isolated database. An early start before schema loading completed was stopped and restarted after all 300 migration versions were verified, latest `20261117150000`.

Runtime resources are cleaned after each QA phase. The isolated database was dropped and its absence verified. The final handoff records lifecycle status and the retained source worktree. No runtime resources are intentionally handed off.
