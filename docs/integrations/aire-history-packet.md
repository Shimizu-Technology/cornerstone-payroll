# Review historical coverage before Stage 2 publication

Stage 1 ships the certified pair paused without running rollout configure tasks. Its Payroll migration still installs the immutable Oct 16 boundary; AIRE has no rollout singleton or calendars. Accounting continues entering hours manually. These steps belong to Stage 2, held until Leon approves a later first connected period and Claude releases the reviewed implementation. Nothing here authorizes deployment or production data changes.

## Meaning of each reviewed disposition

Every record binds the installation UUID, permanent person UUID, entry ID/current version, current payable-content checksum, hours, category, work date, approval state and authenticated provenance. It also carries `actor_id`, a 10–2000 character `reason` and a 10–2000 character `evidence` reference to the private accounting review.

| Disposition | Required source evidence | Accounting meaning |
|---|---|---|
| `historical_baseline` | Complete unchanged immutable manual batch lines, checksum-verified authenticated batch export, committed external run belonging to this company | Already represented in manual payroll; no check-delivery assertion |
| `legacy_frozen_batch_baseline` | Checksum-verified frozen payload and retained snapshot, no source/revision/audit edit after finalization, numeric owner resolved to confirmed permanent mapping, exact employee REG/OT balance against the actually linked committed run | Lower-strength historical representation; missing original UUID/version/checksum remain explicit; approval and delivery unchanged |
| `pending_review` | Pending or NULL approval, no active allocation/hold; any existing baseline must independently verify | Keep approval and payment undetermined; retain represented and unrepresented pending work separately |
| `owed` | Approved completed positive hours, no representation/allocation/hold, exactly one matching active explicit-routing case | Reviewer has established debt; retain its existing case for a single explicit future route |
| `payment_evidence_pending` | Whole-source current attestation, unchanged source, no allocation or baseline | Reported payment remains held pending exact evidence |
| `not_payable` | Denied source with no representation/allocation/hold | Preserve the existing denial |
| `no_payable_hours` | Zero source hours with no representation/allocation/hold | No payable hours in this row |

Baseline verification fetches the immutable batch through AIRE and verifies its canonical payload checksum, employee, exact line key, category, work date and REG/OT/total hours. The authenticated history export supplies the immutable snapshot digest/content comparison and actual manual-processing event. A manifest label or a pay-run ID alone is insufficient. A partial line set, overlapping claims, another company's run, changed source, missing chronology or conflicting processing remains blocked.

Legacy batches can lack captured UUIDs, versions or payable-content checksums. Export their actual missing fields without inventing them. A reviewed legacy-owner binding uses the frozen numeric owner and the authenticated current permanent owner; it never matches names. Chronology observations can detect subsequent edits but cannot reconstruct missing original chronology. Retain that limitation in the accounting evidence. Unknown comparisons cannot pass as unchanged baselines. The separately reviewed `legacy_frozen_batch_baseline` class may instead use a retained snapshot plus an independently unchanged source: every retained payable field must match, source creation/update and break timestamps must precede finalization, and later revision observations and successful edit audits must show no later edit. A migration backfill observation is not an original version; it is checked only for consistency with that unchanged source. Missing original fields remain missing. Any source edit, snapshot mismatch, missing source, conflicting link or exact committed-run balance mismatch blocks the row. Never add an unlinked supplemental run or round a difference to obtain coverage.

An ownerless row without a permanent source UUID remains blocked; do not invent an identity to complete coverage. Each baseline also requires the mapped employee’s complete frozen batch REG/OT balance to equal that employee’s local committed-run hours; manual payroll has aggregate earnings, so individual source lines are not matched to whole payroll items. A mismatch remains blocked. The new dispositions are read-only accounting coverage. Applying them writes the existing approval receipt and any separately reviewed identity links. It creates no wages, allocations, payment-issued event, time approval or check handout. Existing delivered-check paths retain their separate exact evidence requirements. Identity/version-only unpaid or hold arrays are no longer sufficient.

## Ordered maintenance procedure

1. Confirm Stage 1's manual payroll is complete. Take fresh paired backups and freeze historical edits while collecting/reviewing the packet. Select a future period with Chels. Configure matching immutable rollout boundaries and the approved schedule while both fleets are paused. Payroll retains its original immutable migration-default column. Before any explicit gate/calendar/publication/history receipt/import, its configure command may append one strictly later initial selection; that selection cannot be updated, deleted or truncated. A previously gated source requires a separately reviewed migration, not another selection. Review overdue cutoff, calendar and outbox inventories; never delete evidence to pass.
2. Reconcile all preceding manual runs and run AIRE's paid-history preview/apply/replay while paused. Include any additional manually processed period using its real snapshot/commit evidence. Preserve genuinely owed 1804 and existing evidence holds. The release-day runner retains its original four known runs and accepts contiguous additional complete manual periods up to an explicit `rollout_starts_on`. Each added period requires a unique external run ID, real snapshot/commit timestamps and a `manual_run_evidence` reference of at least 20 characters. It refuses gaps, duplicate runs or an uncovered interval before the rollout.
3. Enable and restart both fleets in an **unpublished maintenance phase**. Verify both enabled statuses and exact builds, with no connected calendar published. Keep Payroll operators frozen during maintenance. Paused APIs cannot perform the required remote pin/link/map/history reads.
4. Pin the correct AIRE installation, link the authorized reviewer account and verify person mappings and earning choices. Missing Solo treatment remains a Chels/Mark decision.
5. Capture an unapproved packet from Payroll `api/` into a private directory:

   ```sh
   umask 077
   SOURCE_ID=1 ACTOR_ID='<reviewer>' HISTORY_THROUGH_WORK_DATE='<latest committed regular end>' \
     AIRE_ROLLOUT_EXPORT_PATH='/private/path/history.DRAFT.json' bin/rails aire_rollout:export
   ```

   The export refuses overwrite and creates mode 0600. All rows start `review_required`, with empty reason/evidence; export is never approval. Leon/Chels assign each truthful type, reason and evidence, including the pending legacy rows. Add separately reviewed identity links or existing exact delivered-check evidence only when actually established. Keep source evidence unchanged. Store no private packet in Git or CI artifacts.
6. Hash the reviewed bytes, then preview. `AIRE_HISTORY_PAGE_SIZE` defaults to 50 (range 1–250); `AIRE_HISTORY_READ_TIMEOUT_SECONDS` defaults to 60 seconds per page (range 1–120). The whole page response shares that budget, response size remains bounded and other request budgets stay unchanged.

   ```sh
   export AIRE_ROLLOUT_MANIFEST_PATH='/private/path/history.reviewed.json'
   export AIRE_ROLLOUT_MANIFEST_SHA256='<SHA-256 of exact reviewed bytes>'
   bin/rails aire_rollout:preview
   ```

   Retain the digest and `disposition_counts`. Require **`history_coverage_verified: true`**; exit zero alone is insufficient. Unknown rows remain an explicit stop. Source changes require a fresh capture and review.
7. Leon authorizes that exact digest/owner through the existing `aire_rollout:apply` approval environment. Production additionally requires `AIRE_ROLLOUT_PRODUCTION_APPROVED=yes`, `AIRE_ROLLOUT_RELEASE_ID`, `AIRE_ROLLOUT_RELEASE_OWNER` and matching `AIRE_ROLLOUT_ACCEPTED_MANIFEST_SHA256`. A nonproduction apply requires `AIRE_ROLLOUT_LOCAL_TEST=1` and an actual database name containing `_rollout_rehearsal_`; do not spoof it. Run `bin/rails aire_rollout:ensure_complete` immediately afterwards. It re-exports source coverage and refuses stale receipts if fresh coverage is false.
8. Only now publish the first connected calendar. Verify its adjacent committed regular run/payday and future cutoff; do not publish any backfilled manual period. For Nov 1–15, an actual committed Oct 16–31 manual run with Nov 15 payday anchors **Nov 22 at 17:00 Pacific/Guam**. Oct 31 belongs to the earlier Oct 1–15 run and is not this anchor.
9. Explicitly route 1804's owed case once after delivery of the eligible calendar. Observe the real controlled-cutoff frozen batch/import/calculation in the disposable rehearsal. Reconcile per employee/category against the approved ledger; pending time stays excluded, OT holds remain visible and post-lock approval opens a late-hours case. Do not invent a Solo earning rate to complete acceptance.

Production requires its own fresh packet, accountant decisions and exact-pair acceptance. Clone evidence and synthetic regression tests never authorize production approval.
