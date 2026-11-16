# Client payroll review loop QA

Owner: implementation worker, GPT-6.1 Sol. Base: `0209afe9165c9d397ee978e6dcbc251112ee1816`; branch `feat/client-review-loop`. No production access. Lead owns independent review, integration, merge and deployment.

## Context and acceptance

Cornerstone staff prepare payroll from retained source files, calculate and review it, then approve to publish the client preview. Assigned clients review PREVIEW checks and pay stubs, approve the exact revision or request changes. Commit is the financial boundary. The company setting controls the client gate at commit. Unapprove withdraws client approval and a later approval publishes a new revision. Payroll files retain source and draft history while directing decisions to the pay run.

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

Initial screenshots preserve the original desktop “Approved” status wording. The pending client status now reads “Ready for your review”; staff pending/change-request labels and the commit-step explanation also reflect the outstanding decision. The corrected labels were exercised during the phone loop. The final UI adds a 44px minimum to review-card buttons; it changes no saved behavior.

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
