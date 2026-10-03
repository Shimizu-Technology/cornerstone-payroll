# AIRE and Cornerstone V2 release

Cornerstone owns payroll calculations, payroll allocations and payment records. A connected time system owns employee time and approvals. Source installation identity, permanent employee UUIDs, immutable batch checksums and payable line keys connect their records without relying on matching names or local database IDs.

For AIRE, regular scheduled paydays are the 15th and the last calendar day. Holidays and weekends do not move those dates. The target regular run's cutoff is seven calendar days after the adjacent previous regular scheduled payday, at 17:00 Pacific/Guam. Adjustment runs and actual check delivery dates do not change that anchor. New or newly approved time after the cutoff remains visible and can be assigned to a later eligible run; it cannot silently alter a finalized batch.

Payroll preparation and payment delivery are separate facts. Leon and Chels process payroll and prepare checks; AIRE controls delivery. A committed run or prepared check does not establish delivery. Source receipts retain the event timestamp and the payment's effective date separately. Voids and failures release the appropriate unpaid balance through explicit lifecycle events.

## Existing history

Existing source connections require approved historical coverage before calendar publication. New empty connections do not inherit another business's history. The release receipt is bound to the company, source installation, accepted manifest digest and approval owner. It is written only after evidence validation and successful source reconciliation.

Never infer payment from a missing receipt, approve the entire legacy candidate file by accepting the scheduling policy, or overwrite old allocations to supply missing UUIDs. Legacy allocations use append-only, explicitly approved identity bindings. Historical classification differences require separate review and do not automatically create payments, deductions or corrected hours.

Leon and Chels approve historical exceptions. The private packet must account for every source entry through at least the latest committed regular period end, including ownerless entries. Each entry must have verified paid evidence, a source evidence hold, or an explicit reviewed unpaid disposition. Compare current source versions, category, work date, employee/company ownership, check hours, standalone check overlaps and actual delivery evidence. The paid evidence must account for the entry’s whole recorded hours, including legitimate partial allocations across separate checks; a matching entry ID alone is insufficient. REG/OT totals must also match when the inventory provides that split. A partial or stale packet cannot open the calendar gate.

Use `scripts/reconciliation_inventory.py` to capture database-enforced read-only snapshots. Supply the explicit private candidate manifest and both SSH destinations; the tool writes private mode-600 snapshots and an unapproved inventory outside Git. `scripts/render_reconciliation_review.py` renders those exact inputs into a private HTML packet. Neither tool approves, pays, applies a manifest or changes either application. Keep employee records and private candidates out of Git, CI artifacts and PR descriptions. The final source inventory is fetched before the completion transaction; the short transaction rechecks local evidence, current approver access, source installation and the latest committed history boundary before writing approval.

## Validation and promotion

1. Run both applications' local gates and browser checks using disposable synthetic databases. Run `scripts/certify_aire_payroll_integration.sh` against the exact candidate AIRE checkout to exercise their HTTP boundary.
2. Review feature PRs against `staging-v2`, including migration safety, receipt retries and partial failures. Preserve existing append-only SQL triggers when updating `schema.rb`.
3. Install the fail-closed V2 poller, direct deploy gate and certificate verifier before either staging branch publishes new images. The older host poller can select independently green applications and cannot enforce a gate it does not contain. Follow `ops/staging-v2/README.md`; preserve the original staging environment and shared services.
4. After reviewed staging merges and successful image publication, dispatch Payroll's registered Quality workflow with both full immutable SHAs. Deploy only when its latest successful attempt has the retained matching pair certificate. Failed, pending, expired or mismatched evidence holds the existing runtime.
5. Rehearse historical reconciliation in staging with an explicit approved packet. Verify resulting receipts, legacy bindings, held/unpaid balances, cutoff behavior, adjustment runs, retries and voids. Production needs its own fresh evidence and accepted manifest; staging success is not production historical approval.

No automatic promotion to `main` or production is part of this release. Back up both databases and uploads before migrations, preserve finalized legacy evidence and verify runtime health after any authorized deployment. Historical revision backfill captures migration-time state; it cannot reconstruct edits that were never recorded before an old cutoff.
