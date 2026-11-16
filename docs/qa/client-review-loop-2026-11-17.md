# Client payroll review loop QA

Owner: implementation worker, GPT-6.1 Sol. Base: `0209afe9165c9d397ee978e6dcbc251112ee1816`; branch `feat/client-review-loop`. No production access. Lead owns independent review, integration, merge and deployment.

## Context and acceptance

Cornerstone staff prepare payroll from retained source files, calculate and review it, then approve. When client approval is enabled, staff approval publishes the client preview. Assigned clients review PREVIEW checks and pay stubs, approve the exact revision or request changes. Commit is the financial boundary. The company setting controls publication, client notification and the approval gate at commit. A pending current change request blocks commit with either setting. Unapprove withdraws client approval and a later approval publishes a new revision. Payroll files retain source and draft history while directing decisions to the pay run.

Sources: `docs/rollout/02-MOSA-CYCLE-RUNBOOK.md`, `docs/ROLE_PERMISSION_MATRIX_2026-05-14.md`, `PayrollReview::RevisionService`, `PayPeriodLifecycleService`, client pay-period controller, payroll submissions actions/serializer, and the lead's November 17 worker brief. The Brain Dump's September 19 Cornerstone priorities note confirms employee-level reconciliation and client-specific setup as live-payroll prerequisites; it is historical context, not current release certification. Render/Netlify are production targets; neither is accessed here.

Experience: operational, existing Cornerstone styling, preview and decisions before the employee table, readable phone controls and explicit acknowledgement. No added motion. Notes remain after failed decisions; history retains prior requests. This is agent-executed affected-flow QA; actual mobile hardware, real email delivery and production payment/printing are excluded.

## Scenario ledger

All cases use synthetic records in owned `cp_test_p2_loop`, local Rails test mode with explicit seeded staff/client identities, and email disabled. Required browser dimensions are desktop 1280px and mobile browser 390px. Each case passes only after both dimensions and saved outcomes are verified.

| Case | Actions and expected result | Desktop | Mobile | Result |
| --- | --- | --- | --- | --- |
| C01 | Staff approves calculated run; current preview appears to client; client views/downloads PREVIEW checks/stubs; acknowledgement gates exact approval; staff commits; persisted state agrees | passed | passed | passed |
| C02 | Client requires a note to request changes; staff sees author/time/note, unapproves, fixes/recalculates and approves; client sees new revision and prior request, approves; staff commits | passed | passed | passed |
| C03 | Unapprove withdraws an approved revision; unchanged amounts cannot reuse approval; stale revision URL/decision rejected | passed | passed | passed |
| C04 | Payroll files retains history, links to preview review, offers no manual draft decisions/uploads/mark-paid; paid follows commit | passed | passed | passed |

Automated coverage separately verifies company authorization, setting-off behavior, notification event/recipient ledger, audit failure rollback and stale checksum rejection. Email transport remains disabled; no delivery claim.

## Execution notes

- Initial automated run: tests asserting calculated-run client approval were updated to the new order. New approval transitions need explicit verified tax-table fixtures.
- The base has no Vitest project named `unit`; `npx vitest run --project unit` returns “No projects matched”. `npm run gate` runs the full `vitest run src` unit suite; `npx tsc -b` is run separately as requested.
- One legacy draft fixture needed its required fingerprint. A heading-pinning Vitest assertion was updated for the retired manual draft card.

## Browser execution

All four cases passed at 1280×800 and 390×844 in the T3 preview browser with seeded `manager` and `client` users. Both runs followed: enter 80 regular hours → calculate → staff approve → client view both PDF pages and download → request two additional hours → staff see author/time/note → unapprove → change to 82 hours → recalculate → staff approve revision 2 → client approve → unapprove and re-approve unchanged amounts → client view and approve revision 3 → staff confirm commit. Reloaded API records independently confirmed committed status, gross $1,230.00 and net $1,064.66 for each run. The stale mobile preview URL returned 422; request specs cover stale decisions and company authorization.

Earlier uploaded PDFs were seeded in local test storage, retained in Payroll files and downloaded at both widths. Both audiences followed the link to the pay-run review. No manual draft upload, decision or mark-paid actions remained. Paid status followed commit. A browser finding exposed a residual Start review button after commit; the serializer now returns only messaging actions for finished runs, and the corrected page was reloaded and verified. There was no page overflow at 390px.

The pending client status reads “Ready for your review”; staff pending/change-request labels and the commit-step explanation reflect the outstanding decision. Review-card buttons have a 44px minimum. The screenshots below were refreshed after the rebase onto PR #474.

See [saved outcomes](client-review-loop-2026-11-17/saved-outcomes.json), [desktop client](client-review-loop-2026-11-17/desktop_client.png), [desktop PDF](client-review-loop-2026-11-17/desktop_pdf.png), [staff change request](client-review-loop-2026-11-17/desktop_staff.png), [phone client](client-review-loop-2026-11-17/mobile_client.png), [phone PDF](client-review-loop-2026-11-17/mobile_pdf.png), [phone staff](client-review-loop-2026-11-17/mobile_staff.png), and retained-file history at [desktop](client-review-loop-2026-11-17/desktop_files.png) / [phone](client-review-loop-2026-11-17/mobile_files.png).

The persisted ledger contains six publication events, six decision events, six audited client preview accesses and four withdrawals. Recipients were the assigned client or configured staff user as appropriate. All email deliveries were skipped with `email_delivery_disabled`; no real email was sent.

## Automated gate and limits

- Broad affected backend batch: 233 examples, zero failures, including the query-count budget and unbatched detail equivalence, lifecycle concurrency, portal notifications, approval/email-attestation behavior and source-file flows. The rollout migration also passed independently. Final follow-up: 59 examples, zero failures, covering the updated Payroll files projection, every review-loop service transition and rollout migration.
- Frontend: lint and `tsc -b` passed; all 192 unit files / 1,870 tests passed. Production-mode local Vite build passed with explicit matching deployment flags. The first gate build refused missing deployment flags; rerunning the build with the repository-required flags passed. Vite reports the existing large-chunk advisory.
- Changed Ruby files: RuboCop passed. Brakeman: zero errors / security warnings. Impeccable advisory scan: no findings on the changed review UI paths.
- No physical-phone keyboard/gesture/PWA, real email transport, printer, bank settlement, production or deployed-release certification. Gate 0's complete E2E lane was not run locally; the changed real-browser loop and full frontend unit suite were run. Required CI and independent review remain with the lead.

## Decisions and cleanup

A single PR implements B8–B10 against main. No stack dependencies. `published_at` separates actionable publication from the older retention-only `sent_for_client_approval_at` marker. Change requests retain immutable author/time/note on the review package; the presenter displays `changes_requested` while the stored review remains pending until superseded. Unapprove supersedes rather than clears approval evidence. Manual draft write routes return a clear 422 recovery message; reads and downloads remain available. Payroll files projects review/paid status from the actual run while retaining old status events.

Existing approved-run handling is documented in the runbook and covered by the migration test. The lead owns independent review, merge, integration with other in-flight PRs and deploy. This worker did not merge or deploy.

Owned Vite/Rails processes and the preview tab were cleaned using lifecycle session `01a1e4fd-7446-70b3-827a-1ae0abcbba80`. The temporary identity-injection Vite configuration was removed. The unique `cp_test_p2_loop` database and task-installed frontend dependencies/build output are removed before handoff. The source worktree and branch are retained for the lead.

## Main update after PR creation

Main advanced to `bdf60ed92895eab676a064d617e2f0526e880188` with PR #474 while this worker was preparing the handoff. The branch was rebased; the only textual conflict was the schema version, resolved to retain both #474's entry-resolution migration and this review-loop migration. Source, configured-field serialization and request changes combined without conflicts. The post-rebase gate adds #474's import-change and standing-change specs. The full frontend rerun had one timeout in an unchanged employee-document pagination test under host contention; a full rerun with two workers is used to distinguish that timing issue from a product regression. Post-rebase results: **262 backend examples passed**, including both rollout migrations, the detail query-count budget, lifecycle concurrency, #474 import/standing changes and the full review-loop transitions. Lint, `tsc -b`, RuboCop and Brakeman passed. The full frontend rerun with two workers passed **192 files / 1,873 tests**. The local Vite build passed.

The entire staff/client loop was repeated on implementation head `6c8573cb0bed721d0b5ad0e8fc9e591969cacbc4` at 1280×800 and 390×844: preview both pages/download → request changes → staff unapprove/fix/recalculate/re-approve → client approve → unapprove/re-approve unchanged → client approve revision 3 → commit. Both roles also reopened Payroll files; earlier PDFs downloaded, the review link worked, paid followed commit, and no manual draft actions or page overflow remained. All four required cases passed again at both widths. Saved outcome and screenshot evidence was refreshed from this combined run.

## Round 2 acceptance — completed

Tested implementation: `7d53a241ffa9778951b2210d57fa6489c94549ed` (November 17 Guam). First action was merging origin/main `6223d5e94d7c7438c079966a3ad92f4679e72f8c`, including #469 and #474. The only conflict was the schema version; retained `20261117150000`. `db:create db:schema:load db:migrate` succeeded in isolated `cp_test_p2_loop` with all migrations recorded. No production access, merge or deployment.

The lead's decision makes client publication and notification opt-in. With the setting off, staff approve and commit without client review; unpublished internal revisions and retention-only markers do not produce client cards, including after commit. A pending current change request blocks commit with either setting. Old Payroll files periods without a live run, including voided linked runs, retain their original status. Outstanding file requests keep the files period incomplete; a live run must be committed for it to show paid.

### Required browser scenarios

Agent executed the actual UI as seeded manager and client in the T3 browser. Rails test mode, synthetic records only, email disabled. Two required cases passed at both dimensions: **2 accepted, 0 failed/blocked/not run** (four loop executions). Mobile coverage is resized browser coverage, not physical hardware/PWA certification.

| Case | Actions and independently verified outcome | 1280×800 | 390×844 |
| --- | --- | --- | --- |
| R2-ON | Enter 80 hours → calculate → staff approve → client opens both PREVIEW pages/downloads and requests two hours → staff Commit disabled with actor/note/recovery message; direct commit also returns 422 → unapprove → enter 82 hours/recalculate/re-approve revision 2 → client acknowledges/approves that revision → staff confirms commit. Earlier request remains in history. Gross $1,230.00 / net $1,064.66 saved for each run. | passed | passed |
| R2-OFF | Setting off before calculation → 80 hours → calculate → staff approve; Commit available, no review panel, and approved run absent from client list → staff confirms commit → client opens finalized run with no review card. Gross $1,200.00 / net $1,040.56 saved for each run. Neither revision published; zero review notification events for these runs. | passed | passed |

Both roles had usable controls and no page overflow at either required width. The phone approval control appears below all employee payroll details. Preview view/downloads recorded two client access audits. The four original loops recorded eight review notification events: four publications and four decisions, with the configured synthetic recipients. All deliveries were skipped because email delivery was disabled.

Supplementary **R2-STALE**: passed at 390×844. An isolated fifth fixture was published, then unapproved/re-approved through the fixture service while its old client card remained open. Clicking approval sent the old revision and returned 422; the card fetched revision 2, displayed “This payroll was updated. Review the latest preview.”, kept the note, cleared acknowledgement and disabled approval until confirmed again. This fixture reset is not counted as a browser execution of the financial loop. Desktop stale recovery was not repeated; unit tests cover stale approval, change-request and preview responses. The fifth fixture added two publication events and was left uncommitted only until database cleanup.

Evidence: [saved outcomes](client-review-loop-round2-2026-11-17/saved-outcomes.json), [commit blocks and stale recovery](client-review-loop-round2-2026-11-17/browser-recovery.json), [desktop preview](client-review-loop-round2-2026-11-17/desktop-preview.png), [phone preview](client-review-loop-round2-2026-11-17/phone-preview.png), [desktop block](client-review-loop-round2-2026-11-17/desktop-commit-blocked.png), [phone block](client-review-loop-round2-2026-11-17/phone-commit-blocked.png), setting-off finalized pages at [desktop](client-review-loop-round2-2026-11-17/desktop-off-finalized.png) / [phone](client-review-loop-round2-2026-11-17/phone-off-finalized.png), and [stale recovery](client-review-loop-round2-2026-11-17/phone-stale-recovery.png).

### Automated checks and repairs

- Combined backend batch: **300 examples, zero failures** on `8626b83f`, covering the review loop, revision service, lifecycle concurrency, client pay periods, submission serializer/query scaling, file requests, detail-read equivalence/budget, #469 eligibility/status transitions, #468 expected entries, staff pay-period/refresh requests, publication migration and submission tenancy. The final client response/history filtering was then verified by **20 request examples, zero failures** on `7d53a241`.
- Full unit Vitest: **192 files / 1,887 tests passed**, two workers with the existing timeouts. Frontend lint and `tsc -b` passed. The public E2E lane passed **158 tests** on the final implementation. Its review fixture explicitly enables client approval and uses staff-approved/published state; both desktop and narrow phone approval bind `revision_id: 91`.
- Full RuboCop: **1,882 files, no offenses**; the final client-only changes also passed their focused scan. Brakeman: **zero errors / warnings**. Local production-mode Vite build passed; its existing large-chunk advisory remains. Impeccable advisory UI scan: no findings.
- Detail reads select without calculation snapshots, fetch only current/shared rows in SQL within the unchanged query budget, and omit source manifests from serialized history. The files list batches live runs/current publications and preloads related list data; a scaling spec verifies query count stays bounded.
- PDF generation runs outside the period lock, followed by locked revision/checksum verification; a changed PDF attempt returns 409 without access audit or bytes. Notification recording uses a rescued savepoint; its failure cannot roll back staff approval or client decisions. Staff email attestation resets when the review identity changes.

Retest trail: the first backend pass found one extra detail query (66 versus the 65-query ceiling); the filtered combined lookup restored the budget. New regression fixtures were corrected to name their source revision and explicitly enable publication; a test matcher typo was repaired. The old portal-file-request spec expected retired manual mark-paid behavior; it now verifies requested/responded files remain incomplete and paid follows commit after withdrawal. The first unit rerun hit the previously observed unchanged employee-document pagination timeout; complete bounded reruns passed. The first public run used the same-origin real-QA proxy, changing mocked download-header visibility and causing four unrelated filename assertions; running with the lane's normal cross-origin API configuration passed all 158 without report changes.

### Cleanup and handoff

Lifecycle session `01a1e53d-306b-7f53-8801-e3f82238d982`: owned Rails/Vite processes and preview tab cleaned; final status has no active owned resources. `cp_test_p2_loop` was dropped and its absence verified. The temporary QA proxy/identity configuration and task-installed frontend dependencies/build output were removed. Shared baseline services stayed available. The PR, branch and source worktree are retained for the lead; no runtime resource handoff.

The lead owns final-head independent review, required CI, integration, merge and deployment. No real email, printer/bank settlement, physical-phone/PWA, full Gate 0 release lane or production certification is claimed.

After this round's checks and cleanup, remote main advanced to `35029d6670a969991928d84f9e0b083cfb9ea50f` with #471 and #472. Those changes were not merged into this worker's tested source. The lead must integrate that newer main and verify the combined report/import/commit-dialog changes before merge. This round's passing evidence covers the merged main base `6223d5e9` plus the fixes above; it is not certification of the later integration.
