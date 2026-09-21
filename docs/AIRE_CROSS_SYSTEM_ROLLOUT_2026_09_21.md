# AIRE and Cornerstone payroll rollout — local rehearsal

This is a release checklist, not authorization to deploy. Leon asked for local testing and his own manual review before anything reaches production.

## What the release will do

- Link the 29 verified AIRE people to their existing Cornerstone employee records by permanent AIRE UUID. Future entries for those people reuse the same link. A new, unverified AIRE person still needs an administrator to review the employee setup; the system must not guess an identity, pay rate, or tax treatment.
- Record delivery evidence for 158 verified issued paychecks. Reconcile 1,315 historical AIRE entries against those checks and acknowledge another 134 entries already attached to finalized AIRE batches. This includes Ma Cristina's 12 May 1–15 entries, whose 37.40 regular hours exactly match issued check 2735. Paid evidence follows the source entry, not a name or total-hour guess. New or changed entries are not silently marked paid.
- Preserve the reviewed historical exceptions, including hours paid at a different regular/overtime classification. Those hours do not reappear in future payroll simply because of the classification difference. Jeremiah's 14 previously attested maintenance entries remain held pending check evidence rather than falsely recorded as confirmed paid.
- Set Francisco “Kiko” San Nicolas's maintenance rate to $16/hour and create his inactive W-2 payroll setup for review. Align Ethan's three CFI wages to $30 flight, $30 ground, and $10 admin.
- Give Chels a single review-and-link action for exact manual-payroll matches across paychecks. It shows the person, check, category, and hours, asks her to verify wage category/rate/gross, then links each exact entry. A failed link stays visible and can be retried; it is never marked paid merely because hours look similar.

## Release gates

1. Finish the production-shaped local replay and an end-to-end browser rehearsal of scheduling, cutoff, import, manual linking, payroll calculation/approval/commitment, payment evidence, and late-hour carryover. Record counts and any exceptions. Leon then tests locally.
2. Review the AIRE and Cornerstone PRs into staging. Do not merge staging into main until Leon approves. Deploy AIRE first so its guarded account links and payment-hold migrations exist before Cornerstone connects.
3. The private historical manifest is bundled in Git **only as AES-256-GCM ciphertext**. The decryption key is outside Git. Before an approved production release, provision the key, the verified plaintext SHA-256, `AIRE_ROLLOUT_PRODUCTION_APPROVED=yes`, and an explicit `AIRE_ROLLOUT_RELEASE_ID` into the one-off predeploy environment. The plaintext is not a runtime secret or a Git file. The local key is stored in the `codex-aire-rollout-manifest-key-20260921` Keychain item and must be securely transferred or rotated during approved release preparation; do not print it in logs or chat.
4. Cornerstone's serialized predeploy applies the verified manifest and requires a completion receipt. A missing key, changed check/identity/source entry, or incomplete replay stops deployment. The replay is idempotent, so an interrupted run can resume after its cause is fixed. AIRE is actively used; entries added since the verified snapshot remain unpaid for later review unless matched by a new payroll run.
5. After deployment, verify mapping counts, issued-entry acknowledgements in both systems, held/unpaid entries, the Chels account link, Francisco/Ethan setup, and the next live pay-run UI. Do not issue or alter real checks during this verification.

## Policy timing to confirm in the local rehearsal

The confirmed rule is that a regular period locks at **5 p.m. Guam time, seven days after that same period's scheduled pay date**; an adjustment run does not reset the clock. Thus the Sep 16–30 example, paid Oct 15, locks Oct 22. Chels can review/import live hours before that lock, but the final immutable AIRE batch arrives *after* the scheduled pay date. The interface must make that distinction clear: a finalized batch cannot be required to issue checks on the earlier pay date. The end-to-end rehearsal must prove how live/manual hours are paid on time and how later entries are held for a subsequent run.
