# PR 478: first lead review follow-up

Worker: GPT-6.1 Sol. Existing worktree `worktrees/cp-known-issues`, branch `fix/payroll-known-issues`, starting head `4a8454fd`. No merge, deploy or production access. The lead's `output/mosa-payroll-workflow-20261116/REVIEW_478_ROUND1.md` governs this round and supersedes the first-round design decisions where noted below. The product remains Cornerstone staff importing client files, reviewing and committing payroll; payroll files and retained selections must survive edits and deletion of a mistaken draft.

## Review acceptance

| Finding | Required repair | Verification |
| --- | --- | --- |
| 1 | Release automatic links before deleting a deletable draft; retain uploaded files/submissions and selected import evidence | Model and delete-request regressions |
| 2 | Release and rematch automatic links after date/eligibility changes; keep imported/selected links authoritative | Model purpose/date/selection regressions |
| 3 | Skip runs owned by another period in live linking and backfill; materialization must not bypass the guard | Live linker, catalog and repeated migration probes |
| 4 | Scope ambiguity to a candidate run, exclude parallel comparisons, and name withdrawing requests as recovery | Model regressions and request flow |
| 5 | Backfill unique free replacements for voided links and warn staff on unresolved voided links | Migration and serializer/model regressions |
| 6 | Avoid company creation locks for correction, supplemental and bonus runs | Lock-order regression plus existing concurrency suites |
| 7 | Commit claims an ambiguous unrequested period only for the chosen eligible run | Lifecycle/model regression |
| 8 | Hide stale details during initial/conflict refresh; use the dialog's current client-review gate; no silent handler refusal | Delayed-load Vitest and parent-controller regression |
| 9 | Place focused, styled warnings beside numbering/requests; show old/new counter and added/resolved requests; omit reload instruction | Vitest and real browser at 1280×800 / 390×844 |

Agent executes affected-flow QA. Synthetic fixtures use only `cp_test_known_issues` and `cp_dev_known_issues`; both were absent at start. Database tasks use both explicit overrides and test mode. Existing listeners/services are borrowed; task servers/tabs will be claimed and cleaned exactly.

## Browser plan

For run and list entry points at each viewport: verify initial loading, happy commit, added/resolved-request conflict, changed-counter conflict, localized warning visibility/focus and re-confirmation. Verify saved status, checks and request-ID audit metadata after each successful retry. Check loading hides old totals/requests and error recovery preserves the intended run. Physical-device/PWA, printer, real email and financial settlement are outside scope.

## Execution

All nine findings have regression coverage. The initial 205-example backend batch passed. The broader 390-example batch passed 389 and caught one remaining old assertion that treated an unselected link as authoritative after a date change. That request case now selects an import first to verify retained evidence; a separate new request case verifies automatic release and replacement matching. The 120-example portal-import rerun passed. **The final combined run passed all 391 examples**, including the material regressions, imports, lifecycle/concurrency, correction and late-hours services, and detail-read budgets. A final link/serializer check also verifies the voided warning without adding null optional fields.

Frontend: all **1,933 tests across 196 files passed**, with 180 affected tests also passing separately. Frontend lint, `tsc -b`, changed-file RuboCop (10 files), and the advisory Impeccable scan passed; the scan reported no findings. No controller implementation changed this round.

The three material regressions cover deleting an auto-linked mistaken draft without deleting the client submission, releasing/rematching an unselected purpose/date association while retaining selected import evidence, and avoiding the unique-index collision in live linking, catalog materialization and repeated backfills. Additional cases cover candidate-only ambiguity, parallel-run exclusion, voided replacement backfill/warnings, nonportal creation lock order and explicit commit-time linkage.

## Browser acceptance

Agent-executed against real local Rails responses and synthetic test-mode data; email uses the test transport. Passed at **1280×800 and 390×844**, from **run and list entry points**: initial loading, happy commit, request changes and counter changes. Twelve runs saved gross $1,200 and net $1,100, each with exactly one commit audit. Eight 409 recoveries were followed by an explicit successful confirmation. Run-page cases added a request; list-page cases resolved the last request at each width.

A temporary browser wrapper delayed actual detail GETs without mocking their responses. While initial or conflict reads were pending, the dialog showed its loading state with no old totals, numbering or requests. React StrictMode issues two detail reads when the list dialog mounts; the probe was adjusted to delay both before checking the loading state. Successful commit still ran through the actual dialog; the concurrent mutations were fixture actions through the real API.

Every conflict warning was styled, adjacent to the affected section, focused and fully within the viewport after reload. Counter warnings named old and new numbers; request warnings named resolved requests or marked additions. The old “Reload the record” suffix was absent. Confirmation reset, and scrolling reached the requests and confirm/cancel controls on phone. No horizontal page overflow was observed. The twelve persisted request-ID audits and check numbers match the browser payloads. See [saved outcomes](payroll-known-issues-round1-2026-11-17/saved-outcomes.json) and [browser traces](payroll-known-issues-round1-2026-11-17/browser-traces.json).

Visual evidence: [desktop run counter](payroll-known-issues-round1-2026-11-17/desktop-run-counter.png), [desktop run requests](payroll-known-issues-round1-2026-11-17/desktop-run-requests.png), [desktop list counter](payroll-known-issues-round1-2026-11-17/desktop-list-counter.png), [desktop resolved request](payroll-known-issues-round1-2026-11-17/desktop-list-requests.png), [mobile run counter](payroll-known-issues-round1-2026-11-17/mobile-run-counter.png), [mobile run requests](payroll-known-issues-round1-2026-11-17/mobile-run-requests.png), [mobile list counter](payroll-known-issues-round1-2026-11-17/mobile-list-counter.png), [mobile resolved request](payroll-known-issues-round1-2026-11-17/mobile-list-requests.png).

The earlier QA ledger remains evidence of the initial implementation; this round supersedes its all-links-authoritative design and earlier conflict copy. Physical-device/PWA, printer, real email, settlement and production were not tested.

Owned Rails PID 20087 (3218), npm/Vite PID 20674 (5218), and the task browser tab were cleaned after QA. Lifecycle session `01a1e657-ef09-7f61-9a8f-3830f0f4cfb8` reports no active owned resources. Final isolated-database cleanup and review state are preserved in the handoff.


Current main advanced to `3a3659a1` with #476's documentation-only runbook update. It is integrated before the round-one push. It changes six documentation files and no product code, database configuration or runtime path; no affected product retest is introduced by that merge.
